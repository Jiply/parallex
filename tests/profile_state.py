"""Verify profile migration preserves shared data and existing private settings."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="parallex-profile-", dir="/tmp") as directory:
        root = Path(directory)
        app = root / "ProfileTests.app/Contents"
        binary = app / "MacOS/ProfileTests"
        binary.parent.mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "ProfileTests", "CFBundleIdentifier": "test.parallex.profile",
            "CFBundlePackageType": "APPL"}))
        relay = binary.parent / "ParallexCodexRelay"
        relay.write_text("#!/bin/sh\nexit 0\n")
        relay.chmod(0o700)
        harness = root / "main.swift"
        harness.write_text('''import Foundation
func check(_ value: Bool, line: UInt = #line) { precondition(value, "check failed at line \\(line)") }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let shared = root.appendingPathComponent("shared")
let accounts = root.appendingPathComponent("accounts")
let account = accounts.appendingPathComponent("test@example.test")
let home = account.appendingPathComponent("home")
let runtime = root.appendingPathComponent("Desktop.app/Contents/Resources/codex")
let bundled = runtime.deletingLastPathComponent().appendingPathComponent("plugins/openai-bundled/plugins")
for name in ["browser", "chrome"] {
  let source = bundled.appendingPathComponent(name)
  try fm.createDirectory(at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
  try fm.createDirectory(at: source.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
  try Data("{\\\"version\\\":\\\"test-version\\\"}".utf8).write(to: source.appendingPathComponent(".codex-plugin/plugin.json"))
  for file in ["scripts/browser-client.mjs", "scripts/browser-service.mjs", "NOTICE"] {
    try Data("vendor-sentinel".utf8).write(to: source.appendingPathComponent(file))
  }
}
try fm.createDirectory(at: shared.appendingPathComponent(".tmp"), withIntermediateDirectories: true)
try fm.createDirectory(at: home, withIntermediateDirectories: true)
let config = "[marketplaces.openai-bundled]\\nsource = \\\"\\(shared.path)/.tmp/bundled-marketplaces/openai-bundled\\\"\\n"
try Data(config.utf8).write(to: shared.appendingPathComponent("config.toml"))
try Data("{\\\"selected-project\\\":\\\"existing\\\"}".utf8).write(to: shared.appendingPathComponent(".codex-global-state.json"))
try Data("keep".utf8).write(to: shared.appendingPathComponent(".tmp/sentinel"))
try Data("shared-transcription".utf8).write(to: shared.appendingPathComponent("transcription-history.jsonl"))
try Data("{}".utf8).write(to: home.appendingPathComponent("auth.json"))
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent("auth.json").path)
for name in [".tmp", "config.toml", "transcription-history.jsonl"] {
  try fm.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: shared.appendingPathComponent(name))
}
let profile = CodexProfile(email: "test@example.test", rootURL: account, homeURL: home, desktopDataURL: account.appendingPathComponent("desktop"))
let manager = CodexProfileManager(sharedHomeURL: shared, accountsHomeURL: accounts)
try manager.prepareInstance(profile, codexExecutableURL: runtime)
let transcription = home.appendingPathComponent("transcription-history.jsonl")
check(try transcription.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
check(try String(contentsOf: transcription, encoding: .utf8) == "shared-transcription")
// Desktop rewrites this file atomically during startup, even with no history.
try Data().write(to: transcription, options: .atomic)
try manager.prepareInstance(profile, codexExecutableURL: runtime)
check(try Data(contentsOf: transcription).isEmpty)
try Data("private-transcription".utf8).write(to: transcription, options: .atomic)
try manager.prepareInstance(profile, codexExecutableURL: runtime)
check(try String(contentsOf: transcription, encoding: .utf8) == "private-transcription")
check(try String(contentsOf: shared.appendingPathComponent("transcription-history.jsonl"), encoding: .utf8) == "shared-transcription")
let browserCache = shared.appendingPathComponent("plugins/cache/openai-bundled/browser")
let cached = browserCache.appendingPathComponent("test-version")
check(try String(contentsOf: cached.appendingPathComponent("NOTICE"), encoding: .utf8) == "vendor-sentinel")
check(home.appendingPathComponent("plugins").resolvingSymlinksInPath().path == shared.appendingPathComponent("plugins").resolvingSymlinksInPath().path)
try fm.removeItem(at: cached.appendingPathComponent("scripts/browser-service.mjs"))
try Data("preserve-damaged-copy".utf8).write(to: cached.appendingPathComponent("local-sentinel"))
try manager.prepareInstance(profile, codexExecutableURL: runtime)
check(fm.fileExists(atPath: cached.appendingPathComponent("scripts/browser-service.mjs").path))
let backups = try fm.contentsOfDirectory(at: browserCache, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".parallex-backup-") }
check(backups.count == 1)
check(fm.fileExists(atPath: backups[0].appendingPathComponent("local-sentinel").path))
check(try home.appendingPathComponent(".tmp").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
check(try String(contentsOf: shared.appendingPathComponent(".tmp/sentinel"), encoding: .utf8) == "keep")
check(try String(contentsOf: shared.appendingPathComponent("config.toml"), encoding: .utf8) == config)
check(try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8).contains(home.appendingPathComponent(".tmp").path))
check(fm.fileExists(atPath: home.appendingPathComponent(".codex-global-state.json").path))
let wrapper = try String(contentsOf: account.appendingPathComponent(".parallex-codex"), encoding: .utf8)
check(wrapper.contains("export CODEX_HOME='\\(shared.path)'"))
check(wrapper.contains("--auth-home '\\(home.path)'"))
check(wrapper.contains("--shared-home '\\(shared.path)'"))
check(wrapper.contains("cli_auth_credentials_store=ephemeral"))
check(!wrapper.contains("cli_auth_credentials_store=file"))
try Data("model = \\\"private-choice\\\"\\n".utf8).write(to: home.appendingPathComponent("config.toml"))
try manager.prepareInstance(profile, codexExecutableURL: runtime)
check(try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8).contains("private-choice"))
try fm.removeItem(at: home.appendingPathComponent("config.toml"))
try fm.createSymbolicLink(at: home.appendingPathComponent("config.toml"), withDestinationURL: root.appendingPathComponent("unrelated"))
do {
  try manager.prepareInstance(profile, codexExecutableURL: runtime)
  fatalError("accepted divergent symlink")
} catch {}
print("PASS: private temp/config/state/transcription, atomic transcription rewrites survive preparation, shared data preserved, divergent links rejected")
''')
        sources = ["CodexProfileManager", "CodexScanner", "CodexMonitor"]
        subprocess.run(["swiftc", "-swift-version", "5", "-module-cache-path", str(root / "module-cache"), str(harness),
                        *[str(ROOT / "Sources" / (name + ".swift")) for name in sources],
                        "-o", str(binary), "-framework", "AppKit", "-framework", "Combine"], check=True)
        subprocess.run([str(binary), str(root)], check=True)


if __name__ == "__main__":
    main()
