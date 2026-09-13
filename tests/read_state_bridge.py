"""Exercise the real Swift bridge against a private fake Codex IPC server."""
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
HOST = "local:" + hashlib.sha256(b'["local","local",null]').hexdigest()


def frame(value):
    payload = json.dumps(value).encode()
    return struct.pack("<I", len(payload)) + payload


def receive(peer):
    def exact(size):
        result = b""
        while len(result) < size:
            chunk = peer.recv(size - len(result))
            assert chunk, "unexpected IPC disconnect"
            result += chunk
        return result
    return json.loads(exact(struct.unpack("<I", exact(4))[0]))


def identity(name):
    return {"kind": "chatgpt", "accountId": name, "userId": "user-" + name}


def event(name, unread, thread="synthetic-thread"):
    return {
        "type": "broadcast", "method": "thread-read-state-changed", "version": 3,
        "sourceClientId": "desktop-" + name,
        "params": {"conversationId": thread, "hostId": "local",
                   "hasUnreadTurn": unread,
                   "context": {"identity": identity(name), "executionHostKey": HOST}},
    }


def initialize(server, client_id="bridge"):
    peer, _ = server.accept()
    peer.settimeout(3)
    request = receive(peer)
    assert request["method"] == "initialize" and request["version"] == 0
    peer.sendall(frame({"type": "response", "method": "initialize",
                        "requestId": request["requestId"], "resultType": "success",
                        "result": {"clientId": client_id}}))
    return peer


def replay(peer, unread, thread="synthetic-thread"):
    messages = [receive(peer), receive(peer)]
    assert {message["params"]["context"]["identity"]["accountId"]
            for message in messages} == {"a", "b"}, messages
    for message in messages:
        assert message["type"] == "broadcast", message
        assert message["method"] == "thread-read-state-changed", message
        assert message["version"] == 3, message
        assert message["params"]["conversationId"] == thread, message
        assert message["params"]["hasUnreadTurn"] is unread, message
        peer.sendall(frame(message))
    return messages


def native_snapshot(home, name, threads):
    key = hashlib.sha256(json.dumps(["chatgpt", name, "user-" + name],
                                   separators=(",", ":")).encode()).hexdigest()
    path = home / name / ".codex-global-state.json"
    value = {"electron-thread-read-state-v1": {
        "version": 1, "unreadByIdentity": {key: {HOST: list(threads)}}}}
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value))
    temporary.replace(path)


def listen(home, name):
    path = home / name / "ipc/ipc.sock"
    path.parent.mkdir(mode=0o700, exist_ok=True)
    path.unlink(missing_ok=True)
    server = socket.socket(socket.AF_UNIX)
    server.bind(str(path))
    path.chmod(0o600)
    server.listen()
    server.settimeout(8)
    return server


def wait_journal(home, condition):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            journal = json.loads((home / "parallex-read-state.json").read_text())
            if condition(journal):
                return journal
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.05)
    raise AssertionError("read-state journal did not converge")


def assert_quiet(peers, duration=0.3):
    for peer in peers:
        peer.settimeout(duration)
        try:
            assert not peer.recv(1), "unexpected broadcast or echo loop"
        except socket.timeout:
            pass
        finally:
            peer.settimeout(3)


def reconciliation(home, binary):
    home.mkdir()
    thread = "offline-thread"
    for name in ["a", "b"]:
        (home / name).mkdir()
        (home / name / "auth.json").write_bytes((home.parent / name / "auth.json").read_bytes())
        (home / name / "auth.json").chmod(0o600)
        native_snapshot(home, name, [thread])
    servers = {name: listen(home, name) for name in ["a", "b"]}
    peers = {}
    process = None

    def start():
        nonlocal process
        process = subprocess.Popen([str(binary), str(home)])
        for name in ["a", "b"]:
            peers[name] = initialize(servers[name], "bridge-" + name)

    def stop():
        nonlocal process
        if process is not None:
            process.terminate()
            process.wait(timeout=5)
            process = None
        for peer in peers.values():
            peer.close()
        peers.clear()

    def receive_replay(name, unread):
        replay(peers[name], unread, thread)
        # A native Desktop accepts its own identity only, then persists that state.
        native_snapshot(home, name, [thread] if unread else [])

    def snapshots_match(unread):
        expected = [thread] if unread else []
        return lambda journal: sum(sorted(value) == expected
            for value in journal.get("snapshots", {}).values()) >= 2

    try:
        start()
        # Native persisted state establishes the offline-change baseline.
        for name in ["a", "b"]:
            receive_replay(name, True)
        wait_journal(home, snapshots_match(True))
        # A is disconnected while B reads the task. A receives the missed read later.
        peers.pop("a").close()
        servers.pop("a").close()
        (home / "a/ipc/ipc.sock").unlink()
        native_snapshot(home, "b", [])
        peers["b"].sendall(frame(event("b", False, thread)))
        forwarded = receive(peers["b"])
        assert forwarded["params"]["hasUnreadTurn"] is False, forwarded
        peers["b"].sendall(frame(forwarded))
        wait_journal(home, lambda journal: journal.get("states", {}).get(thread) is False)
        servers["a"] = listen(home, "a")
        peers["a"] = initialize(servers["a"], "bridge-a-reconnected")
        receive_replay("a", False)
        wait_journal(home, snapshots_match(False))
        assert_quiet(peers.values())
        # The entire bridge can restart without resurrecting a persisted read tombstone.
        stop()
        start()
        for name in ["a", "b"]:
            receive_replay(name, False)
        assert_quiet(peers.values())
        # Establish unread in both native files and save that baseline before stopping.
        native_snapshot(home, "a", [thread])
        peers["a"].sendall(frame(event("a", True, thread)))
        forwarded = receive(peers["a"])
        assert forwarded["params"]["hasUnreadTurn"] is True, forwarded
        peers["a"].sendall(frame(forwarded))
        receive_replay("b", True)
        wait_journal(home, snapshots_match(True))
        stop()
        # A reads the task while Parallex is stopped; B remains stale on disk.
        native_snapshot(home, "a", [])
        start()
        for name in ["a", "b"]:
            receive_replay(name, False)
        wait_journal(home, lambda journal: journal.get("states", {}).get(thread) is False
                     and snapshots_match(False)(journal))
        # Echoes and acknowledged native files stay quiet across a periodic refresh.
        assert_quiet(peers.values(), duration=3.2)
    finally:
        stop()
        for server in servers.values():
            server.close()


def main():
    with tempfile.TemporaryDirectory(prefix="parallex-", dir="/tmp") as directory:
        home = Path(directory)
        (home / "ipc").mkdir(mode=0o700)
        for name in ["a", "b"]:
            profile = home / name
            profile.mkdir()
            claims = {"https://api.openai.com/auth": {
                "chatgpt_account_id": name, "user_id": "user-" + name}, "exp": 9999999999}
            encoded = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
            auth = profile / "auth.json"
            auth.write_text(json.dumps({"tokens": {"access_token": "test." + encoded + ".test"}}))
            auth.chmod(0o600)
        harness = home / "main.swift"
        harness.write_text('''import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let bridge = CodexReadStateBridge(codexHomeURL: root, profiles: {
  ["a", "b"].map { name in
    let home = root.appendingPathComponent(name)
    return CodexProfile(email: name, rootURL: home, homeURL: home, desktopDataURL: home)
  }
})
bridge.start()
RunLoop.main.run()
''')
        binary = home / "bridge"
        sources = ["CodexReadStateBridge", "CodexProfileManager", "CodexScanner", "CodexMonitor"]
        subprocess.run(["swiftc", "-swift-version", "5", str(harness),
                        *[str(ROOT / "Sources" / (name + ".swift")) for name in sources],
                        "-o", str(binary), "-framework", "AppKit", "-framework", "Combine"], check=True)
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(home / "ipc/ipc.sock"))
        os.chmod(home / "ipc/ipc.sock", 0o600)
        server.listen()
        server.settimeout(6)
        process = subprocess.Popen([str(binary), str(home)])
        try:
            peer = initialize(server)
            # Split framing and payload across writes, then verify both read directions.
            for name, unread, target in [("a", True, "b"), ("b", False, "a")]:
                message = event(name, unread)
                data = frame(message)
                for offset in range(0, len(data), 7):
                    peer.sendall(data[offset:offset + 7])
                forwarded = receive(peer)
                expected = copy.deepcopy(message)
                expected["sourceClientId"] = "bridge"
                expected["params"]["context"]["identity"] = identity(target)
                assert forwarded == expected
                # The server echoes broadcasts to peers: our own messages must not loop.
                peer.sendall(frame(forwarded))
            rejected = [event("unknown", True), event("a", True), event("a", True), event("a", True)]
            rejected[1]["params"]["hostId"] = "remote"
            rejected[2]["params"]["context"]["executionHostKey"] = "local:other-host"
            rejected[3]["version"] = 999
            peer.sendall(b"".join(frame(value) for value in rejected))
            peer.settimeout(0.3)
            try:
                assert not peer.recv(1), "unexpected forwarded event or loop"
            except socket.timeout:
                pass
            # Reconnect after Codex closes its socket and assign a new session.
            peer.close()
            peer = initialize(server)
            replay(peer, False)
            peer.sendall(frame(event("a", False)))
            assert receive(peer)["params"]["hasUnreadTurn"] is False
            # A private profile socket can appear while the bridge is running.
            private_dir = home / "a/ipc"
            private_dir.mkdir(mode=0o700)
            private_server = socket.socket(socket.AF_UNIX)
            private_server.bind(str(private_dir / "ipc.sock"))
            os.chmod(private_dir / "ipc.sock", 0o600)
            private_server.listen()
            private_server.settimeout(8)
            private_peer = initialize(private_server, "private-bridge")
            replay(private_peer, False)
            try:
                for origin, destination, name, unread in [
                    (peer, private_peer, "b", True),
                    (private_peer, peer, "a", False),
                ]:
                    origin.sendall(frame(event(name, unread)))
                    same_socket = receive(origin)
                    cross_socket = [receive(destination), receive(destination)]
                    assert {value["params"]["context"]["identity"]["accountId"]
                            for value in cross_socket} == {"a", "b"}
                    assert all(value["params"]["hasUnreadTurn"] is unread
                               for value in cross_socket)
                    # Echo bridge broadcasts on either socket; global client IDs prevent loops.
                    origin.sendall(frame(same_socket))
                    for value in cross_socket:
                        destination.sendall(frame(value))
                for connected in [peer, private_peer]:
                    connected.settimeout(0.3)
                    try:
                        assert not connected.recv(1), "cross-socket broadcast loop"
                    except socket.timeout:
                        pass
                for connected in [peer, private_peer]:
                    connected.settimeout(3)
                # Native archive events synchronize display state without identity rewriting.
                for method, version in [("thread-archived", 2), ("thread-unarchived", 1)]:
                    message = {
                        "type": "broadcast", "method": method, "version": version,
                        "sourceClientId": "desktop-a",
                        "params": {"hostId": "local", "conversationId": "synthetic-thread"},
                    }
                    if method == "thread-archived":
                        message["params"]["cwd"] = "/synthetic-workspace"
                    private_peer.sendall(frame(message))
                    forwarded = receive(peer)
                    expected = copy.deepcopy(message)
                    expected["sourceClientId"] = "bridge"
                    assert forwarded == expected
                    peer.sendall(frame(forwarded))
                # Ownership, inference, approvals, queued actions and streams stay private.
                forbidden = ["thread-owner-discovery", "thread-follower-start-turn",
                             "thread-follower-command-approval-decision",
                             "thread-queued-followups-changed", "thread-stream-state-changed",
                             "app-connect-oauth-callback-received", "query-cache-invalidate"]
                for method in forbidden:
                    for kind in ["broadcast", "request"]:
                        private_peer.sendall(frame({
                            "type": kind, "method": method, "version": 1,
                            "sourceClientId": "desktop-a",
                            "params": {"hostId": "local", "conversationId": "synthetic-thread"},
                        }))
                for method, version in [("thread-archived", 1), ("thread-unarchived", 2)]:
                    private_peer.sendall(frame({
                        "type": "broadcast", "method": method, "version": version,
                        "sourceClientId": "desktop-a",
                        "params": {"hostId": "local", "conversationId": "synthetic-thread"},
                    }))
                for connected in [peer, private_peer]:
                    connected.settimeout(0.3)
                    try:
                        assert not connected.recv(1), "execution event forwarded or metadata loop"
                    except socket.timeout:
                        pass
                private_peer.close()
                private_peer = initialize(private_server, "private-reconnected")
                replay(private_peer, False)
                peer.settimeout(3)
                private_peer.sendall(frame(event("a", True)))
                assert receive(private_peer)["params"]["hasUnreadTurn"] is True
                assert all(receive(peer)["params"]["hasUnreadTurn"] is True for _ in range(2))
            finally:
                private_peer.close()
                private_server.close()
            peer.close()
        finally:
            process.terminate()
            process.wait(timeout=5)
            server.close()
        reconciliation(home / "offline", binary)
        print("PASS: read/archive sync, execution isolation, framing, loop prevention, "
              "identity/host/version filters, missed-read replay, durable read tombstones, "
              "offline native changes, and quiet reconciliation")


if __name__ == "__main__":
    main()
