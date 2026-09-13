"""Check browser runtime paths and account boundaries using disposable app bundle fixtures."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="parallex-browser-config-") as directory:
        root = Path(directory)
        relay = (ROOT / "Sources/CodexEventRelay.swift").read_text()
        configuration = relay.split("private struct CodexBrowserConfiguration {", 1)[1].split(
            "/// When accounts share local storage", 1)[0]
        source = root / "browser.swift"
        source.write_text("import Foundation\nprivate struct CodexBrowserConfiguration {" + configuration + '''
while let line = readLine() {
  let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
  let configuration = CodexBrowserConfiguration(executable: request["executable"] as! String,
    authHome: request["authHome"] as! String, sharedHome: request["sharedHome"] as! String)
  var response: [String: Any] = ["available": configuration != nil]
  if let configuration {
    response["command"] = configuration.command
    response["environment"] = configuration.environment
    response["arguments"] = configuration.arguments
    if let raw = request["raw"] as? String {
      response["normalized"] = String(decoding: configuration.normalize(Data(raw.utf8)), as: UTF8.self)
    }
  }
  let data = try JSONSerialization.data(withJSONObject: response)
  print(String(decoding: data, as: UTF8.self))
  fflush(stdout)
}
''')
        binary = root / "browser-test"
        subprocess.run(["swiftc", "-module-cache-path", str(root / "module-cache"),
            str(source), "-o", str(binary)], check=True)
        resources = root / 'App "quoted" \\ fixture.app' / "Contents" / "Resources"
        runtime = resources / "codex"
        browser = resources / "plugins/openai-bundled/plugins/browser"
        manifest = browser / ".codex-plugin/plugin.json"
        service = browser / "scripts/browser-service.mjs"
        node = resources / "cua_node"
        node_repl = node / "bin/node_repl"
        for file in [runtime, manifest, service, node_repl, node / "bin/node"]:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text("#!/bin/sh\nexit 0\n")
        node_repl.chmod(0o700)
        (node / "lib/node_modules").mkdir(parents=True)
        manifest.write_text(json.dumps({"name": "browser", "version": "1.2.3"}))
        shared = root / "shared state"
        cached = shared / "plugins/cache/openai-bundled/browser/1.2.3"
        cached.mkdir(parents=True)
        bootstrap = cached / "scripts/browser-client.mjs"
        bootstrap.parent.mkdir()
        bootstrap.write_text("// Fixture module\n")
        profiles = [root / 'account "first"' / "home", root / "account second" / "home"]
        for profile in profiles:
            profile.mkdir(parents=True)
            (profile / "plugins").symlink_to(shared / "plugins", target_is_directory=True)
        process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        def request(profile, raw=None):
            value = {"executable": str(runtime), "authHome": str(profile), "sharedHome": str(shared)}
            if raw is not None:
                value["raw"] = raw
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            assert selector.select(timeout=5), "browser configuration harness timed out"
            return json.loads(process.stdout.readline())

        try:
            first, second = [request(profile) for profile in profiles]
            assert first["available"] and second["available"]
            for result, profile in zip([first, second], profiles):
                env = result["environment"]
                assert env["CODEX_HOME"] == str(profile)
                assert env["CODEX_CLI_PATH"] == str(profile.parent / ".parallex-codex")
                assert result["command"] == str(node_repl)
                assert env["NODE_REPL_NODE_PATH"] == str(node / "bin/node")
                assert env["NODE_REPL_NODE_MODULE_DIRS"] == str(node / "lib/node_modules")
                assert env["BROWSER_USE_CODEX_APP_VERSION"] == "1.2.3"
                services = json.loads(env["NODE_REPL_TRUSTED_SERVICES"])
                assert services == {"browser": str(service), "sky": "@oai/sky/service"}
                trust = env["NODE_REPL_TRUSTED_CODE_PATHS"].split(":")
                linked_bootstrap = profile / "plugins" / bootstrap.relative_to(shared / "plugins")
                assert linked_bootstrap.resolve() == bootstrap.resolve()
                assert any(os.path.commonpath([str(linked_bootstrap.resolve()), str(Path(trusted).resolve())]) == str(Path(trusted).resolve())
                    for trusted in trust), "Symlinked plugin resolves outside the trusted roots"
                args = result["arguments"]
                assert all(arg == "-c" for arg in args[::2])
                overrides = {}
                for arg in args[1::2]:
                    key, value = arg.split("=", 1)
                    overrides[key] = json.loads(value)
                assert overrides["mcp_servers.node_repl.command"] == str(node_repl)
                assert {key.removeprefix("mcp_servers.node_repl.env."): value
                    for key, value in overrides.items() if ".env." in key} == env
            assert first["environment"]["CODEX_CLI_PATH"] != second["environment"]["CODEX_CLI_PATH"]
            native_services = json.dumps({"browser": "@oai/browser-desktop/service",
                "sky": "@oai/sky/service", "extra": "@fixture/other-service"})
            native = {"command": "/old/node_repl", "args": ["--native-flag"], "enabled": True,
                "instructions": "Keep the native instructions verbatim.", "startup_timeout_sec": 25,
                "env": {"CODEX_HOME": "/wrong-profile", "CODEX_CLI_PATH": "/wrong-wrapper",
                    "NATIVE_PIPE": "native-pipe", "NODE_REPL_TRUSTED_SERVICES": native_services}}
            message = {"id": "native-resume", "method": "thread/resume", "params": {
                "threadId": "fixture", "config": {"mcp_servers.node_repl": native,
                    "mcp_servers.other": {"command": "/keep/other"}, "unrelated": "retain"}}}
            normalized = json.loads(request(profiles[0], json.dumps(message))["normalized"])
            actual = normalized["params"]["config"]["mcp_servers.node_repl"]
            assert actual["command"] == str(node_repl)
            assert actual["env"]["CODEX_HOME"] == str(profiles[0])
            assert actual["env"]["NATIVE_PIPE"] == "native-pipe"
            assert actual["env"]["NODE_REPL_TRUSTED_SERVICES"] == native_services
            for field in ["instructions", "args", "enabled", "startup_timeout_sec"]:
                assert actual[field] == native[field], field
            assert normalized["params"]["config"]["mcp_servers.other"] == {"command": "/keep/other"}
            assert normalized["params"]["config"]["unrelated"] == "retain"
            batch = {"id": 19, "method": "config/batchWrite", "params": {"edits": [
                {"keyPath": "mcp_servers.node_repl", "value": native, "mergeStrategy": "replace"},
                {"keyPath": "mcp_servers.other", "value": {"enabled": False}}], "other": "preserved"}}
            normalized = json.loads(request(profiles[1], json.dumps(batch))["normalized"])
            assert normalized["params"]["edits"][0]["value"]["env"]["CODEX_HOME"] == str(profiles[1])
            assert normalized["params"]["edits"][0]["mergeStrategy"] == "replace"
            assert normalized["params"]["edits"][1] == batch["params"]["edits"][1]
            assert normalized["params"]["other"] == "preserved"
            for value in [None, False, {"enabled": False}]:
                message = {"id": 20, "method": "thread/start", "params": {
                    "config": {"mcp_servers.node_repl": value}}}
                normalized = json.loads(request(profiles[0], json.dumps(message))["normalized"])
                actual = normalized["params"]["config"]["mcp_servers.node_repl"]
                if isinstance(value, dict):
                    assert actual["enabled"] is False
                else:
                    assert actual is value
            for raw in [' { "id": 30, "method": "thread/read", "params": {"threadId":"x"} }\n',
                '{"id":31,"method":"thread/resume","params":{"config":{"other":1}}}\n',
                'not JSON\n']:
                assert request(profiles[0], raw)["normalized"] == raw
            manifest.write_text(json.dumps({"name": "browser", "version": "2.0.4"}))
            assert request(profiles[0])["environment"]["BROWSER_USE_CODEX_APP_VERSION"] == "2.0.4"
            assert request(profiles[0])["command"] == str(node_repl)
            node_repl.chmod(0o600)
            assert request(profiles[0])["available"] is False
            node_repl.chmod(0o700)
            service.unlink()
            assert request(profiles[0])["available"] is False
        finally:
            process.stdin.close()
            process.wait(timeout=5)
            selector.close()
            assert process.returncode == 0, process.stderr.read()
    print("browser account isolation, symlink trust, native config preservation, version upgrades, and argument quoting passed")


if __name__ == "__main__":
    main()
