"""Exercise shared runtime storage and private authentication through real process pipes."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="parallex-credentials-") as directory:
        root = Path(directory)
        source = root / "relay.swift"
        source.write_text((ROOT / "Sources/CodexEventRelay.swift").read_text().replace(
            "org.curvelabs.Parallex.codex-thread-event", "test.parallex." + uuid.uuid4().hex))
        binary = root / "relay"
        subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(root / "module-cache"),
            str(source), "-o", str(binary)], check=True)
        shared = root / "shared"
        private = root / "private"
        shared.mkdir(mode=0o700)
        private.mkdir(mode=0o700)
        shared_auth = shared / "auth.json"
        shared_auth.write_text("canonical credential sentinel")
        private_auth = private / "auth.json"
        private_auth.write_text(json.dumps({"tokens": {
            "access_token": "private-initial", "account_id": "private-account"}}))
        private_auth.chmod(0o600)
        runtime = root / "codex"
        runtime.write_text("#!" + sys.executable + "\n" + '''
import json, os, sys
from pathlib import Path
home = Path(os.environ["CODEX_HOME"])
store = [sys.argv[i + 1] for i, arg in enumerate(sys.argv[:-1]) if arg == "-c"
         and sys.argv[i + 1].startswith("cli_auth_credentials_store=")][-1]
private = store.endswith("=file")
if private and (home / "exit-before-init").exists():
    sys.exit(0)
token = None
pending_refresh = None

def emit(message):
    print(json.dumps(message), flush=True)

def save(value):
    path = home / "auth.json"
    path.write_text(json.dumps({"tokens": {"access_token": value, "account_id": "private-account"}}))
    path.chmod(0o600)

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    params = request.get("params") or {}
    if method == "initialize":
        emit({"id": request_id, "result": {"ready": True}})
        if private and (home / "exit-after-init").exists():
            sys.exit(0)
    elif method == "account/login/start":
        if private:
            save("private-login")
            emit({"id": request_id, "result": {"type": "chatgpt", "loginId": "test-login", "authUrl": "https://example.invalid/login"}})
            emit({"method": "account/login/completed", "params": {"loginId": "test-login", "success": True}})
        else:
            token = params["accessToken"]
            emit({"method": "account/updated", "params": {"authMode": "chatgptAuthTokens"}})
            emit({"id": request_id, "result": {"type": "chatgptAuthTokens"}})
    elif method == "account/logout":
        if private:
            (home / "auth.json").unlink(missing_ok=True)
        token = None
        emit({"id": request_id, "result": {}})
    elif method in ("getAuthStatus", "account/read"):
        assert private, "Credential reads must use the profile's managed authentication"
        if params.get("refreshToken"):
            save("private-refreshed")
        path = home / "auth.json"
        current = json.loads(path.read_text())["tokens"]["access_token"] if path.exists() else None
        if method == "getAuthStatus":
            result = {"authMethod": "chatgpt" if current else None,
                "authToken": current if params.get("includeToken") else None, "requiresOpenaiAuth": True}
        else:
            result = {"account": {"type": "chatgpt", "email": "profile@example.invalid"} if current else None}
        emit({"id": request_id, "result": result})
    elif method == "audit/state":
        emit({"id": request_id, "result": {"home": str(home), "store": store, "tokenState": token}})
    elif method == "audit/refresh":
        pending_refresh = request_id
        emit({"id": "server-refresh", "method": "account/chatgptAuthTokens/refresh", "params": {"reason": "unauthorized", "previousAccountId": "private-account"}})
    elif request_id == "server-refresh":
        if "error" in request:
            emit({"id": pending_refresh, "error": request["error"]})
        else:
            token = request["result"]["accessToken"]
            emit({"id": pending_refresh, "result": {"refreshed": True}})
''')
        runtime.chmod(0o700)
        process = subprocess.Popen([str(binary), "--auth-home", str(private), "--shared-home",
            str(shared), str(runtime), "app-server", "--stdio", "-c", "cli_auth_credentials_store=file"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b""
        request_id = 0

        def request(method, params=None, allow_error=False):
            nonlocal buffer, request_id
            request_id += 1
            process.stdin.write((json.dumps({"id": request_id, "method": method,
                "params": params or {}}) + "\n").encode())
            process.stdin.flush()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                for key, _ in selector.select(max(0, deadline - time.monotonic())):
                    data = os.read(key.fileobj.fileno(), 65536)
                    assert data, "unexpected EOF"
                    buffer += data
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        message = json.loads(line)
                        if message.get("id") == request_id:
                            if allow_error:
                                return message
                            assert "error" not in message, message
                            return message["result"]
            raise AssertionError("request timed out: " + method)

        try:
            request("initialize", {"clientInfo": {"name": "test", "version": "1"}})
            process.stdin.write(b'{"method":"initialized"}\n')
            process.stdin.flush()
            state = request("audit/state")
            assert state == {"home": str(shared), "store": "cli_auth_credentials_store=ephemeral",
                "tokenState": "private-initial"}, state
            assert request("getAuthStatus", {"includeToken": False, "refreshToken": False}) == {
                "authMethod": "chatgpt", "authToken": None, "requiresOpenaiAuth": True}
            assert request("getAuthStatus", {"includeToken": True, "refreshToken": False}) == {
                "authMethod": "chatgpt", "authToken": "private-initial", "requiresOpenaiAuth": True}
            assert request("account/read", {"refreshToken": False}) == {
                "account": {"type": "chatgpt", "email": "profile@example.invalid"}}
            assert request("audit/state")["tokenState"] == "private-initial"
            assert request("getAuthStatus", {"includeToken": True, "refreshToken": True})["authToken"] == "private-refreshed"
            assert request("audit/state")["tokenState"] == "private-refreshed"
            assert request("account/read", {"refreshToken": True})["account"]["type"] == "chatgpt"
            assert request("audit/state")["tokenState"] == "private-refreshed"
            request("audit/refresh")
            assert request("audit/state")["tokenState"] == "private-refreshed"
            request("account/login/start", {"type": "chatgpt"})
            # A second request observes the helper's completion and subsequent installation.
            deadline = time.monotonic() + 5
            while request("audit/state")["tokenState"] != "private-login":
                assert time.monotonic() < deadline
            request("account/logout")
            assert request("audit/state")["tokenState"] is None
            assert request("getAuthStatus", {"includeToken": True, "refreshToken": False})["authToken"] is None
            assert not private_auth.exists()
            assert shared_auth.read_text() == "canonical credential sentinel"
        finally:
            process.stdin.close()
            process.wait(timeout=5)
            errors = process.stderr.read()
            assert b"private-initial" not in errors and b"private-refreshed" not in errors
            assert process.returncode == 0, errors
        for failure in ["exit-before-init", "exit-after-init"]:
            unavailable = root / failure
            unavailable.mkdir(mode=0o700)
            (unavailable / failure).touch()
            process = subprocess.Popen([str(binary), "--auth-home", str(unavailable), "--shared-home",
                str(shared), str(runtime), "app-server", "--stdio"], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            buffer = b""
            request_id = 0
            try:
                request("initialize", {"clientInfo": {"name": "test", "version": "1"}})
                time.sleep(0.1)
                failure_result = request("account/logout", allow_error=True)
                assert "credential process stopped" in failure_result.get("error", {}).get("message", ""), failure_result
                # Credential failure does not take the local runtime down or strand another RPC.
                assert request("audit/state")["home"] == str(shared)
                failure_result = request("account/login/start", {"type": "chatgpt"}, allow_error=True)
                assert "error" in failure_result, failure_result
                failure_result = request("audit/refresh", allow_error=True)
                assert "credential process stopped" in failure_result.get("error", {}).get("message", ""), failure_result
                for method in ["getAuthStatus", "account/read"]:
                    failure_result = request(method, {"includeToken": True, "refreshToken": False}, allow_error=True)
                    assert "credential process stopped" in failure_result.get("error", {}).get("message", ""), failure_result
                assert request("audit/state")["home"] == str(shared)
                assert process.poll() is None
            finally:
                process.stdin.close()
                process.wait(timeout=5)
                assert process.returncode == 0, process.stderr.read()
                selector.close()
    print("native credential reads, inference isolation, refresh, login/logout, helper failure, and canonical auth preservation passed")


if __name__ == "__main__":
    main()
