"""Verify real macOS launch/reopen events using the app delegate and inert services."""
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix="parallex-launch-", dir="/tmp") as directory:
        root = Path(directory)
        app = root / "LaunchTests.app"
        contents = app / "Contents"
        binary = contents / "MacOS/LaunchTests"
        binary.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "LaunchTests",
            "CFBundleIdentifier": "test.parallex.launch",
            "CFBundlePackageType": "APPL",
            "NSPrincipalClass": "NSApplication",
            "LSUIElement": True,
        }))
        events = root / "events"
        stubs = root / "Services.swift"
        stubs.write_text('''import AppKit
func record(_ event: String) {
  let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("events")
  let handle = try! FileHandle(forWritingTo: path)
  defer { try? handle.close() }
  try! handle.seekToEnd()
  try! handle.write(contentsOf: Data("\\(event)\\n".utf8))
}
final class CodexMonitor {}
final class CodexReadStateBridge { func start() {} ; func stop() {} }
final class CodexProfileManager { func startNotificationRouters() {} }
final class StatusItemController {
  init(monitor: CodexMonitor) {}
  func start() { record("start:\\(ProcessInfo.processInfo.processIdentifier)") }
  func stop() {}
  func showMenu() { record("menu") }
}
''')
        subprocess.run([
            "swiftc", "-swift-version", "5", "-parse-as-library",
            str(ROOT / "Sources/ParallexApp.swift"), str(stubs),
            "-o", str(binary), "-framework", "AppKit",
        ], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        events.touch()

        def wait_for(predicate):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                lines = events.read_text().splitlines()
                if predicate(lines):
                    return lines
                time.sleep(0.05)
            raise AssertionError(events.read_text())

        def stop():
            for line in events.read_text().splitlines():
                if line.startswith("start:"):
                    try:
                        os.kill(int(line.split(":")[1]), signal.SIGTERM)
                    except ProcessLookupError:
                        pass

        try:
            subprocess.run(["open", "-a", str(app)], check=True)
            wait_for(lambda lines: lines.count("menu") == 1)
            for count in [2, 3]:
                subprocess.run(["open", "-a", str(app)], check=True)
                lines = wait_for(lambda lines: lines.count("menu") == count)
                assert sum(line.startswith("start:") for line in lines) == 1
        finally:
            stop()
        print("PASS: cold launch and repeated reopen request the menu in one app process")


if __name__ == "__main__":
    main()
