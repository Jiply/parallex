"""Verify native writer release and active-turn protection with the installed Codex runtime."""
import json
import concurrent.futures
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(sys.argv[1] if len(sys.argv) > 1 else "/Applications/ChatGPT.app/Contents/Resources/codex")


class Client:
    def __init__(self, command, shared):
        environment = dict(os.environ, CODEX_HOME=str(shared), CODEX_SQLITE_HOME=str(shared))
        self.process = subprocess.Popen(command, env=environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.sequence = 0
        self.closed = set()
        response = self.request("initialize", {"clientInfo": {
            "name": "parallex_handoff_test", "version": "1"}, "capabilities": {
                "experimentalApi": True, "optOutNotificationMethods": ["thread/closed"]}})
        assert "result" in response, response
        self.process.stdin.write(b'{"method":"initialized"}\n')
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        self.process.stdin.write((json.dumps({"id": self.sequence, "method": method,
            "params": params}) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            for key, _ in self.selector.select(max(0, deadline - time.monotonic())):
                data = os.read(key.fileobj.fileno(), 65536)
                assert data, "unexpected EOF"
                self.buffer += data
                while b"\n" in self.buffer:
                    line, self.buffer = self.buffer.split(b"\n", 1)
                    message = json.loads(line)
                    if message.get("method") == "thread/closed":
                        self.closed.add(message["params"]["threadId"])
                    if message.get("id") == self.sequence:
                        return message
        raise AssertionError("request timed out: " + method)

    def stop(self):
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait()
        self.selector.close()


def main():
    assert RUNTIME.is_file(), "Pass the installed Codex executable as the first argument"
    root = Path(tempfile.mkdtemp(prefix="parallex-writer-test-"))
    clients = []
    try:
        source = root / "relay.swift"
        relay_source = (ROOT / "Sources/CodexEventRelay.swift").read_text().replace(
            "org.curvelabs.Parallex.codex-thread-", "test.parallex." + uuid.uuid4().hex + ".")
        # Delay delivery of the real native close to deterministically exercise an overlapping submit.
        output_marker = "bridge.receiveOutput(line)"
        assert relay_source.count(output_marker) == 1
        relay_source = relay_source.replace(
            output_marker,
            '''
            if ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["method"] as? String == "thread/closed" {
              outputQueue.asyncAfter(deadline: .now() + 0.3) { bridge.receiveOutput(line) }
            } else { bridge.receiveOutput(line) }
          ''')
        marker = 'send(["id": id, "method": "thread/unsubscribe", "params": ["threadId": threadID]])'
        assert marker in relay_source
        relay_source = relay_source.replace(marker, marker + '''
      try? Data().write(to: URL(fileURLWithPath: sharedHome).appendingPathComponent("unsubscribe-observed"))''')
        source.write_text(relay_source)
        binary = root / "relay"
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(root / "module-cache"), str(source), "-o", str(binary)], check=True)
        shared = root / "shared"
        shared.mkdir(mode=0o700)
        flags = ["-c", "cli_auth_credentials_store=ephemeral", "-c", "features.plugins=false",
            "-c", "features.remote_plugin=false", "-c", "features.apps=false", "app-server", "--stdio"]
        fixture = Client([str(RUNTIME)] + flags, shared)
        clients.append(fixture)
        thread = fixture.request("thread/start", {"cwd": str(root), "model": "gpt-6-astra",
            "excludeTurns": True})["result"]["thread"]
        thread_id = thread["id"]
        # No credentials are available: this persists a fixture without any billable inference.
        fixture.request("turn/start", {"threadId": thread_id, "input": [
            {"type": "text", "text": "Local writer coordination fixture."}]})
        time.sleep(0.4)
        fixture.stop()
        clients.remove(fixture)
        profiles = [root / "first", root / "second"]
        for profile in profiles:
            profile.mkdir(mode=0o700)
            clients.append(Client([str(binary), "--auth-home", str(profile), "--shared-home",
                str(shared), str(RUNTIME)] + flags, shared))
        first, second = clients
        params = {"threadId": thread_id, "cwd": str(root), "excludeTurns": True}
        assert "result" in first.request("thread/resume", params)
        started = time.monotonic()
        result = second.request("thread/resume", params)
        assert "result" in result, result
        assert time.monotonic() - started < 5
        first.request("thread/loaded/list", {})
        assert thread_id in first.closed, "Ownership changed before a native thread/closed event"
        resumed_turn = first.request("turn/start", {"threadId": thread_id, "input": [
            {"type": "text", "text": "Active local fixture without credentials."}]})
        assert "result" in resumed_turn, resumed_turn
        second.request("thread/loaded/list", {})
        assert thread_id in second.closed, "Returning to the old window did not reacquire its own writer"
        first.closed.clear()
        denied = second.request("thread/resume", params)
        assert "another billing account instance" in denied.get("error", {}).get("message", ""), denied
        first.request("thread/loaded/list", {})
        assert thread_id not in first.closed, "The active task was closed"
        assert "result" in second.request("thread/read", {"threadId": thread_id, "includeTurns": False})
        for client in clients:
            assert client.request("getAuthStatus", {"includeToken": False,
                "refreshToken": False})["result"]["authMethod"] is None
        assert not (shared / "auth.json").exists()
        fixture = Client([str(RUNTIME)] + flags, shared)
        clients.append(fixture)
        overlap_id = fixture.request("thread/start", {"cwd": str(root), "model": "gpt-6-astra",
            "excludeTurns": True})["result"]["thread"]["id"]
        fixture.request("turn/start", {"threadId": overlap_id, "input": [
            {"type": "text", "text": "Overlapping writer fixture."}]})
        time.sleep(0.4)
        fixture.stop()
        clients.remove(fixture)
        overlap = {"threadId": overlap_id, "cwd": str(root), "excludeTurns": True}
        assert "result" in first.request("thread/resume", overlap)
        release_marker = shared / "unsubscribe-observed"
        release_marker.unlink(missing_ok=True)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            opening = pool.submit(second.request, "thread/resume", overlap)
            deadline = time.monotonic() + 5
            while not release_marker.exists():
                assert time.monotonic() < deadline, "release did not begin"
                time.sleep(0.01)
            submitted = first.request("turn/start", {"threadId": overlap_id, "input": [
                {"type": "text", "text": "Submit while native close is pending."}]})
            assert "result" in submitted, submitted
            opening.result(timeout=15)
        history = first.request("thread/turns/list", {"threadId": overlap_id, "limit": 100})
        assert len(history["result"]["data"]) == 2, "The overlapping turn was lost or replayed"
    finally:
        for client in clients:
            client.stop()
        shutil.rmtree(root, ignore_errors=True)
    print("native idle handoff, Desktop opt-outs, switch-back + overlapping-submit recovery, active-turn protection, and unauthenticated reads passed")


if __name__ == "__main__":
    main()
