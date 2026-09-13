"""Check relay framing, notification filtering, and EOF against real child processes."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="parallex-relay-") as directory:
        folder = Path(directory)
        source = folder / "relay.swift"
        # Isolate distributed notifications from running desktop applications.
        source.write_text((ROOT / "Sources/CodexEventRelay.swift").read_text().replace(
            "org.curvelabs.Parallex.codex-thread-event", "test.parallex." + uuid.uuid4().hex))
        binary = folder / "relay"
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(folder / "module-cache"), str(source), "-o", str(binary)], check=True)
        normal = b'{"id":1,"result":"normal"}\n'
        response = json.dumps({"id": 2, "result": "x" * (5 * 1024 * 1024)}).encode() + b"\n"
        tail = b'{"id":3,"result":"unterminated"}'
        payload = folder / "payload"
        payload.write_bytes(response)
        ready = folder / "ready"
        release = folder / "release"
        child = folder / "child.py"
        child.write_text('''import os, sys, time
from pathlib import Path
root = Path(sys.argv[1])
data = (root / "payload").read_bytes()
os.write(1, b'{"id":1,"result":"normal"}\\n')
os.write(1, data[:65536])
(root / "ready").touch()
while not (root / "release").exists(): time.sleep(0.01)
for offset in range(65536, len(data), 8192):
 os.write(1, data[offset:offset + 8192])
os.write(1, b'{"id":3,"result":"unterminated"}')
sys.exit(7)
''')
        receiver = subprocess.Popen([str(binary), sys.executable, str(child), str(folder)],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            with concurrent.futures.ThreadPoolExecutor() as pool:
                result = pool.submit(receiver.communicate, timeout=20)
                deadline = time.monotonic() + 10
                while not ready.exists():
                    assert time.monotonic() < deadline, "child failed to write initial fragment"
                    time.sleep(0.01)
                notification = {"method": "thread/name/updated", "params": {
                    "threadId": "test-" + uuid.uuid4().hex, "threadName": "Test"}}
                events = [notification, {"method": "thread/started", "params": {}},
                          {"method": "thread/status/changed", "params": {}}]
                producer = "import sys,time;sys.stdout.write(" + repr(
                    "".join(json.dumps(event) + "\n" for event in events)) + ");sys.stdout.flush();time.sleep(0.5)"
                sent = subprocess.run([str(binary), sys.executable, "-c", producer],
                                      capture_output=True, timeout=10)
                assert sent.returncode == 0, sent.stderr
                time.sleep(0.2)
                release.touch()
                output, errors = result.result(timeout=20)
            assert receiver.returncode == 7, (receiver.returncode, errors)
            lines = output.splitlines(keepends=True)
            assert len(lines) == 4, [len(line) for line in lines]
            assert lines[0] == normal
            assert json.loads(lines[1]) == notification, "foreign notification did not arrive during fragment"
            assert lines[2] == response, "fragmented response changed or interleaved"
            assert lines[3] == tail, "EOF tail lost or newline added"
            assert all(json.loads(line).get("method") not in {
                "thread/started", "thread/status/changed"} for line in lines)
            for _ in range(5):
                quick = subprocess.run([str(binary), sys.executable, "-c",
                                        "import sys;sys.stdout.write('tail');sys.exit(9)"],
                                       capture_output=True, timeout=5)
                assert (quick.stdout, quick.returncode) == (b"tail", 9), quick
        finally:
            if receiver.poll() is None:
                receiver.kill()
                receiver.wait()
    print("event relay framing, filtering, fragmented 5 MB response, EOF, and exit checks passed")


if __name__ == "__main__":
    main()
