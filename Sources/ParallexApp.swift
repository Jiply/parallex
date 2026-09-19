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
  private let readStateBridge = CodexReadStateBridge()
  private var statusItemController: StatusItemController?

  /// When Parallex launches, this function deliberately makes it a Dock-free menu-bar utility.
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)

    let statusItemController = StatusItemController(monitor: monitor)
    self.statusItemController = statusItemController
    statusItemController.start()
    DispatchQueue.global(qos: .utility).async {
      CodexProfileManager().startNotificationRouters()
    }
    readStateBridge.start()

    let launchEvent = NSAppleEventManager.shared().currentAppleEvent
    let backgroundLaunch =
      launchEvent?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
      || launchEvent?.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem) != nil
    if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true,
      !backgroundLaunch, !NSApplication.shared.isHidden
    {
      statusItemController.showMenu()
    }
  }

  /// When Spotlight or Finder reopens this windowless app, this function reveals its menu.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    statusItemController?.showMenu()
    return false
  }

  /// When Parallex terminates, this function releases polling and process resources.
  func applicationWillTerminate(_ notification: Notification) {
    statusItemController?.stop()
    readStateBridge.stop()
  }
}
