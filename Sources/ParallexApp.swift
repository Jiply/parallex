import AppKit

@main
enum ParallexApplication {
  /// When the executable starts, this function owns the application delegate for the full run loop.
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let monitor = CodexMonitor()
  private var statusItemController: StatusItemController?

  /// When Parallex launches, this function deliberately makes it a Dock-free menu-bar utility.
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)

    let statusItemController = StatusItemController(monitor: monitor)
    self.statusItemController = statusItemController
    statusItemController.start()
  }

  /// When Parallex terminates, this function releases polling and process resources.
  func applicationWillTerminate(_ notification: Notification) {
    statusItemController?.stop()
  }
}
