"""Exercise the installed native IPC protocol without launching Desktop or reading credentials."""
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Sources/CodexIPCRouter.cjs"
RESOURCES = Path("/Applications/ChatGPT.app/Contents/Resources")
ARCHIVE = RESOURCES / "app.asar"
NODE = RESOURCES / "cua_node/bin/node"


def send(peer, value):
    data = json.dumps(value).encode()
    peer.sendall(struct.pack("<I", len(data)) + data)


def receive(peer, predicate):
    def exact(length):
        value = b""
        while len(value) < length:
            data = peer.recv(length - len(value))
            assert data, "unexpected native IPC disconnect"
            value += data
        return value

    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        value = json.loads(exact(struct.unpack("<I", exact(4))[0]))
        if predicate(value):
            return value
    raise AssertionError("missing native IPC response")


def connect(home, name):
    peer = socket.socket(socket.AF_UNIX)
    peer.settimeout(5)
    peer.connect(str(home / "ipc/ipc.sock"))
    send(peer, {"type": "request", "requestId": name, "sourceClientId": "initializing-client",
                "version": 0, "method": "initialize", "params": {"clientType": "desktop"}})
    response = receive(peer, lambda value: value.get("type") == "response"
                       and value.get("requestId") == name)
    assert response["resultType"] == "success", response
    return peer, response["result"]["clientId"]


def wait_status(home, owns):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        try:
            value = json.loads((home / "ipc/parallex-router.json").read_text())
            if value["ready"] and value["ownsRouter"] is owns:
                os.kill(value["pid"], 0)
                assert set(value) == {"pid", "ready", "ownsRouter"}, value
                for name in ["parallex-router.json", "parallex-router.lock", "ipc.sock"]:
                    assert (home / "ipc" / name).stat().st_mode & 0o777 == 0o600, name
                return value
        except (FileNotFoundError, ProcessLookupError, json.JSONDecodeError):
            pass
        time.sleep(0.05)
    raise AssertionError("native router readiness did not converge")


def stop(process):
    if process.poll() is None:
        process.terminate()
    output, error = process.communicate(timeout=5)
    assert not error, error.decode()
    return output


def protocol(first, second):
    a, aid = connect(first, "a")
    b, bid = connect(first, "b")
    other, _ = connect(second, "other-account")
    try:
        params = {"hostId": "local", "conversationId": "synthetic-thread", "hasUnreadTurn": True}
        send(a, {"type": "broadcast", "sourceClientId": aid, "version": 3,
                 "method": "thread-read-state-changed", "params": params})
        message = receive(b, lambda value: value.get("method") == "thread-read-state-changed")
        assert message["sourceClientId"] == aid and message["params"] == params, message
        other.settimeout(0.25)
        try:
            value = receive(other, lambda value: value.get("method") == "thread-read-state-changed")
            raise AssertionError("read event crossed private account sockets: " + str(value))
        except socket.timeout:
            pass
        send(a, {"type": "request", "sourceClientId": aid, "method": "thread-owner-discovery",
                 "version": 1, "requestId": "owner-probe",
                 "params": {"hostId": "local", "conversationId": "synthetic-thread"}})
        discovery = receive(b, lambda value: value.get("type") == "client-discovery-request")
        send(b, {"type": "client-discovery-response", "requestId": discovery["requestId"],
                 "response": {"canHandle": True}})
        request = receive(b, lambda value: value.get("type") == "request"
                          and value.get("method") == "thread-owner-discovery")
        send(b, {"type": "response", "requestId": request["requestId"], "resultType": "success",
                 "method": request["method"], "handledByClientId": bid,
                 "result": {"supportsUntrustedAppInput": True}})
        response = receive(a, lambda value: value.get("type") == "response"
                           and value.get("requestId") == "owner-probe")
        assert response["handledByClientId"] == bid and response["result"]["supportsUntrustedAppInput"]
        try:
            value = receive(other, lambda value: value.get("type") == "client-discovery-request")
            raise AssertionError("execution request crossed account sockets: " + str(value))
        except socket.timeout:
            pass
    finally:
        for peer in [a, b, other]:
            peer.close()


def main():
    if sys.platform != "darwin" or not all(path.exists() for path in [ARCHIVE, NODE, Path("/usr/bin/lockf")]):
        print("SKIP: native IPC integration requires macOS and the installed ChatGPT app")
        return
    processes = []
    with tempfile.TemporaryDirectory(prefix="parallex-ipc-", dir="/tmp") as temporary:
        root = Path(temporary)
        first, second, concurrent, takeover = [root / name for name in ["a", "b", "c", "d"]]
        # A reachable global legacy endpoint must never combine the private billing domains.
        legacy_root = root / "legacy"
        legacy_directory = legacy_root / "codex-ipc"
        legacy_directory.mkdir(parents=True, mode=0o700)
        legacy_socket = legacy_directory / ("ipc-" + str(os.getuid()) + ".sock")
        legacy = socket.socket(socket.AF_UNIX)
        legacy.bind(str(legacy_socket))
        legacy_socket.chmod(0o600)
        legacy.listen()
        legacy.settimeout(0.25)
        environment = {**os.environ, "TMPDIR": str(legacy_root)}

        def start(home):
            process = subprocess.Popen([str(NODE), str(SCRIPT), str(ARCHIVE), str(home)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
            processes.append(process)
            return process

        try:
            a = start(first)
            b = start(second)
            assert wait_status(first, True)["pid"] == a.pid
            assert wait_status(second, True)["pid"] == b.pid
            try:
                connection, _ = legacy.accept()
                connection.close()
                raise AssertionError("daemon connected to the global legacy router")
            except socket.timeout:
                pass
            protocol(first, second)
            duplicate = start(first)
            assert duplicate.wait(timeout=5) == 0
            assert wait_status(first, True)["pid"] == a.pid
            cold = [start(concurrent) for _ in range(4)]
            winner = wait_status(concurrent, True)["pid"]
            for process in cold:
                if process.pid != winner:
                    assert process.wait(timeout=5) == 0
            owner = next(process for process in cold if process.pid == winner)
            # SIGKILL leaves stale readiness on disk; the kernel must release the lifetime lock.
            owner.kill()
            owner.wait(timeout=5)
            replacement = start(concurrent)
            assert wait_status(concurrent, True)["pid"] == replacement.pid
            # Simulate a pre-existing Desktop with the same unmodified native IPC implementation.
            program = SCRIPT.read_text().rsplit("\ntry {", 1)[0] + """
process.env.CODEX_HOME = process.argv[2];
process.env.TMPDIR = process.argv[2];
const NativeClient = openArchive(process.argv[1]).ipcClientClass();
const client = new NativeClient('desktop', {reportNonFatal() {}});
client.addAnyBroadcastHandler(function receiveBroadcast() {});
client.waitUntilInitialized().then(function ready() { process.stdout.write('ready\\n'); });
setInterval(function keepAlive() {}, 1000);
"""
            desktop = subprocess.Popen([str(NODE), "-e", program, str(ARCHIVE), str(takeover)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            processes.append(desktop)
            assert select.select([desktop.stdout], [], [], 5)[0], "native owner did not start"
            assert desktop.stdout.readline() == b"ready\n"
            successor = start(takeover)
            assert wait_status(takeover, False)["pid"] == successor.pid
            stop(desktop)
            assert wait_status(takeover, True)["pid"] == successor.pid
            print("PASS: installed ASAR loader, native broadcast/request routing, private accounts, "
                  "concurrent singleton, crash recovery, legacy socket isolation, and native takeover")
        finally:
            legacy.close()
            for process in processes:
                assert not stop(process), "router produced unexpected stdout"


if __name__ == "__main__":
    main()
