import AppKit
import Combine

private enum NativeMenuStyle {
  static let rowWidth: CGFloat = 420
  static let rowHeight: CGFloat = 24
  static let twoLineRowHeight: CGFloat = 36
  static let horizontalPadding: CGFloat = 14
  static let iconContainerSize: CGFloat = 16
  static let iconSize: CGFloat = 16
  static let itemSpacing: CGFloat = 8
  static let trailingSpacing: CGFloat = 4
  static let defaultFont = NSFont.menuFont(ofSize: 0)
  static let sessionDetailsFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
  static let headingFont = NSFont.systemFont(ofSize: defaultFont.pointSize, weight: .semibold)
}

private final class MenuFlexRowView: NSView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let accessibilitySuffix: [String]

  /// When a display row is created, this initializer lays it out as one native horizontal stack.
  init(
    title: String,
    subtitle: String? = nil,
    image: NSImage? = nil,
    imageSize: CGFloat = NativeMenuStyle.iconSize,
    reservesIconSpace: Bool = true,
    trailingTexts: [String] = [],
    titleFont: NSFont = NativeMenuStyle.defaultFont,
    titleColor: NSColor = .labelColor,
    lineBreakMode: NSLineBreakMode = .byTruncatingTail,
    height: CGFloat = NativeMenuStyle.rowHeight
  ) {
    accessibilitySuffix = [subtitle].compactMap { $0 } + trailingTexts
    super.init(frame: NSRect(x: 0, y: 0, width: NativeMenuStyle.rowWidth, height: height))
    autoresizingMask = [.width]
    setAccessibilityElement(true)

    let rowStack = NSStackView()
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    rowStack.orientation = .horizontal
    rowStack.alignment = .centerY
    rowStack.distribution = .fill
    rowStack.spacing = NativeMenuStyle.itemSpacing
    rowStack.setAccessibilityElement(false)
    rowStack.edgeInsets = NSEdgeInsets(
      top: 0,
      left: NativeMenuStyle.horizontalPadding,
      bottom: 0,
      right: NativeMenuStyle.horizontalPadding
    )

    if image != nil || reservesIconSpace {
      let iconContainer = NSView()
      iconContainer.setAccessibilityElement(false)
      iconContainer.widthAnchor.constraint(
        equalToConstant: NativeMenuStyle.iconContainerSize
      ).isActive = true
      iconContainer.heightAnchor.constraint(
        equalToConstant: NativeMenuStyle.iconContainerSize
      ).isActive = true
      rowStack.addArrangedSubview(iconContainer)

      if let image {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = titleColor
        imageView.setAccessibilityElement(false)
        iconContainer.addSubview(imageView)
        NSLayoutConstraint.activate([
          imageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
          imageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
          imageView.widthAnchor.constraint(equalToConstant: imageSize),
          imageView.heightAnchor.constraint(equalToConstant: imageSize),
        ])
      }
    }

    titleLabel.font = titleFont
    titleLabel.textColor = titleColor
    titleLabel.lineBreakMode = lineBreakMode
    titleLabel.maximumNumberOfLines = 1
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setAccessibilityElement(false)

    let textView: NSView
    if let subtitle {
      let subtitleLabel = NSTextField(labelWithString: subtitle)
      subtitleLabel.font = NativeMenuStyle.sessionDetailsFont
      subtitleLabel.textColor = .secondaryLabelColor
      subtitleLabel.lineBreakMode = .byTruncatingTail
      subtitleLabel.maximumNumberOfLines = 1
      subtitleLabel.toolTip = subtitle
      subtitleLabel.setAccessibilityElement(false)

      let textStack = NSStackView(views: [titleLabel, subtitleLabel])
      textStack.orientation = .vertical
      textStack.alignment = .leading
      textStack.spacing = 0
      textStack.setAccessibilityElement(false)
      textView = textStack
    } else {
      textView = titleLabel
    }
    textView.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    rowStack.addArrangedSubview(textView)

    if !trailingTexts.isEmpty {
      for (index, text) in trailingTexts.enumerated() {
        let label = NSTextField(labelWithString: text)
        label.font = NativeMenuStyle.defaultFont
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityElement(false)
        rowStack.addArrangedSubview(label)

        if index < trailingTexts.count - 1 {
          rowStack.setCustomSpacing(NativeMenuStyle.trailingSpacing, after: label)
        }
      }
    }

    addSubview(rowStack)
    NSLayoutConstraint.activate([
      rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      rowStack.topAnchor.constraint(equalTo: topAnchor),
      rowStack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    updateTitle(title)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    return nil
  }

  /// When a row title changes, this function updates its visible and accessible text.
  func updateTitle(_ title: String) {
    titleLabel.stringValue = title
    titleLabel.toolTip = title
    setAccessibilityLabel(([title] + accessibilitySuffix).joined(separator: ", "))
  }

}

final class StatusItemController: NSObject, NSMenuDelegate {
  private let monitor: CodexMonitor
  private let profileManager = CodexProfileManager()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let menu = NSMenu()
  private let profileActionQueue = DispatchQueue(
    label: "org.curvelabs.Parallex.profile-actions",
    qos: .userInitiated
  )
  private let hideEmailAddressesKey = "hideEmailAddresses"
  private var menuOpen = false
  private var hoverOpenPending = false
  private var suppressHoverOpenUntilExit = false
  private var snapshotCancellable: AnyCancellable?

  init(monitor: CodexMonitor) {
    self.monitor = monitor
    super.init()
    configureStatusItem()
    configureMenu()
    observeSnapshot()
  }

  /// When the status item is deallocated, this function removes its menu-bar slot.
  deinit {
    NSStatusBar.system.removeStatusItem(statusItem)
  }

  /// When the pointer enters the status item, this function opens the native menu.
  @objc func mouseEntered(with event: NSEvent) {
    guard !menuOpen, !hoverOpenPending, !suppressHoverOpenUntilExit else { return }

    hoverOpenPending = true
    monitor.refresh()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard !self.menuOpen, self.hoverOpenPending else {
        self.hoverOpenPending = false
        return
      }
      self.statusItem.button?.performClick(nil)
      self.hoverOpenPending = false
    }
  }

  /// When the pointer leaves the status item, this function permits the next deliberate hover-open.
  @objc func mouseExited(with event: NSEvent) {
    hoverOpenPending = false
    suppressHoverOpenUntilExit = false
  }

  /// When the native menu requests fresh content, this function rebuilds it from the latest snapshot.
  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildMenu(with: monitor.snapshot)
    monitor.refresh()
  }

  /// When native menu tracking begins, this function prevents duplicate hover opens.
  func menuWillOpen(_ menu: NSMenu) {
    hoverOpenPending = false
    menuOpen = true
  }

  /// When native menu tracking ends, this function prepares the latest content for the next reveal.
  func menuDidClose(_ menu: NSMenu) {
    menuOpen = false
    suppressHoverOpenUntilExit = pointerIsInsideStatusItem()
    rebuildMenu(with: monitor.snapshot)
  }

  /// When menu tracking ends, this function checks whether the pointer could immediately reopen it.
  private func pointerIsInsideStatusItem() -> Bool {
    guard let button = statusItem.button, let window = button.window else { return false }
    let buttonPoint = button.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return button.bounds.contains(buttonPoint)
  }

  /// When Parallex starts, this function performs the first observation refresh.
  func start() {
    monitor.start()
  }

  /// When Parallex stops, this function ends observation.
  func stop() {
    monitor.stop()
  }

  /// When the menu-bar slot is created, this function uses the standard square system-item treatment.
  private func configureStatusItem() {
    statusItem.autosaveName = "org.curvelabs.Parallex.status-item"
    statusItem.isVisible = true
    guard let button = statusItem.button else { return }

    ParallexIcon.statusItemImage.accessibilityDescription = "Parallex"
    button.image = ParallexIcon.statusItemImage
    button.imageScaling = .scaleProportionallyDown
    button.imagePosition = .imageOnly
    button.toolTip = "Parallex · Codex billing and sessions"

    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    button.addTrackingArea(trackingArea)
  }

  /// When the dropdown is created, this function lets NSMenu own appearance and interaction.
  private func configureMenu() {
    menu.autoenablesItems = false
    menu.delegate = self
    statusItem.menu = menu
    rebuildMenu(with: .empty)
  }

  /// When session count changes, this function updates accessibility and the next native menu.
  private func observeSnapshot() {
    snapshotCancellable = monitor.$snapshot
      .receive(on: RunLoop.main)
      .sink { [weak self] snapshot in
        guard let self else { return }

        let count = snapshot.sessions.count
        self.statusItem.button?.setAccessibilityLabel(count == 1
          ? "Parallex, 1 Codex session running"
          : "Parallex, \(count) Codex sessions running")

        if !self.menuOpen {
          self.rebuildMenu(with: snapshot)
        }
      }
  }

  /// When data or privacy state changes, this function rebuilds standard macOS menu items.
  private func rebuildMenu(with snapshot: CodexSnapshot) {
    menu.removeAllItems()

    let hideEmailAddresses = UserDefaults.standard.bool(forKey: hideEmailAddressesKey)
    let sessionCount = snapshot.sessions.count
    let menuImageSize = NSSize(width: 16, height: 16)
    let summaryDescription = sessionCount == 1
      ? "1 Codex session running"
      : "\(sessionCount) Codex sessions running"
    let summaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    ParallexIcon.menuItemImage.size = NSSize(
      width: NativeMenuStyle.iconSize,
      height: NativeMenuStyle.iconSize
    )
    summaryItem.view = MenuFlexRowView(
      title: "Parallex",
      image: ParallexIcon.menuItemImage,
      trailingTexts: [summaryDescription],
      titleFont: NativeMenuStyle.headingFont
    )
    summaryItem.isEnabled = false
    menu.addItem(summaryItem)
    menu.addItem(.separator())

    let launchableProfiles = profileManager.profiles().filter(\.hasCredentials)
    let openAllTitle = "Open one Codex desktop instance per billing account"
    let openAllItem = NSMenuItem(
      title: openAllTitle,
      action: #selector(openAllInstances),
      keyEquivalent: ""
    )
    openAllItem.target = self
    let openAllImage = NSImage(
      systemSymbolName: "rectangle.on.rectangle.angled",
      accessibilityDescription: nil
    )
    openAllImage?.isTemplate = true
    openAllImage?.size = menuImageSize
    openAllItem.image = openAllImage
    openAllItem.isEnabled = !launchableProfiles.isEmpty
    menu.addItem(openAllItem)

    menu.addItem(.separator())
    let sectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    sectionItem.view = MenuFlexRowView(
      title: "Active sessions by billing account",
      reservesIconSpace: false,
      titleFont: NativeMenuStyle.headingFont,
      titleColor: .secondaryLabelColor
    )
    sectionItem.isEnabled = false
    menu.addItem(sectionItem)

    if snapshot.accounts.isEmpty {
      let accountItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      accountItem.view = MenuFlexRowView(
        title: "No billing accounts available",
        reservesIconSpace: true,
        titleColor: .secondaryLabelColor
      )
      accountItem.isEnabled = false
      menu.addItem(accountItem)
    } else {
      for account in snapshot.accounts {
        let accountSessions = snapshot.sessions.filter { $0.accountID == account.id }
        let runningCount = accountSessions.count
        let accountName = hideEmailAddresses && account.email?.isEmpty == false
          ? "Email hidden"
          : account.displayName
        let accountItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let accountImage = NSImage(
          systemSymbolName: account.kind == "apiKey" ? "key" : "person.crop.circle",
          accessibilityDescription: nil
        )
        accountImage?.isTemplate = true
        accountImage?.size = menuImageSize
        accountItem.isEnabled = false
        accountItem.toolTip = accountName
        let runningDescription = runningCount == 1 ? "1 running" : "\(runningCount) running"
        accountItem.view = MenuFlexRowView(
          title: accountName,
          image: accountImage,
          imageSize: 14,
          trailingTexts: [accountTypeName(for: account), "·", runningDescription],
          lineBreakMode: .byTruncatingMiddle
        )
        menu.addItem(accountItem)

        if accountSessions.isEmpty {
          let idleItem = NSMenuItem(
            title: "",
            action: nil,
            keyEquivalent: ""
          )
          idleItem.view = MenuFlexRowView(
            title: "No active sessions",
            titleColor: .secondaryLabelColor
          )
          idleItem.isEnabled = false
          menu.addItem(idleItem)
          continue
        }

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short

        for session in accountSessions {
          let sessionTitle = session.title
          let accountChanged = session.billingConfidence == .changed

          var sessionDetails = [session.workspace, session.originator]
          if let startedAt = session.startedAt {
            sessionDetails.append(
              relativeFormatter.localizedString(for: startedAt, relativeTo: Date())
            )
          }
          if accountChanged {
            sessionDetails.append("credentials changed")
          }
          if session.subagentCount > 0 {
            sessionDetails.append(session.subagentCount == 1
              ? "1 subagent"
              : "\(session.subagentCount) subagents")
          }
          let sessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
          sessionItem.view = MenuFlexRowView(
            title: sessionTitle,
            subtitle: sessionDetails.joined(separator: " · "),
            reservesIconSpace: true,
            height: NativeMenuStyle.twoLineRowHeight
          )
          sessionItem.isEnabled = false
          sessionItem.toolTip = session.title
          menu.addItem(sessionItem)
        }
      }
    }

    menu.addItem(.separator())

    let privacyItem = NSMenuItem(
      title: "Hide email",
      action: #selector(toggleEmailPrivacy),
      keyEquivalent: ""
    )
    privacyItem.target = self
    privacyItem.setAccessibilityLabel(hideEmailAddresses ? "Hide email, on" : "Hide email, off")
    let privacySymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    let privacyImage = NSImage(
      systemSymbolName: hideEmailAddresses ? "checkmark.square.fill" : "square",
      accessibilityDescription: nil
    )?.withSymbolConfiguration(privacySymbolConfiguration)
    privacyImage?.isTemplate = true
    privacyImage?.size = NSSize(width: 15, height: 15)
    privacyItem.image = privacyImage
    menu.addItem(privacyItem)

    let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
    refreshItem.target = self
    let refreshImage = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
    refreshImage?.isTemplate = true
    refreshImage?.size = NSSize(width: 15, height: 15)
    refreshItem.image = refreshImage
    menu.addItem(refreshItem)

    menu.addItem(.separator())

    let quitItem = NSMenuItem(title: "Quit Parallex", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
  }

  /// When email visibility changes, this function persists it for the next native menu.
  @objc private func toggleEmailPrivacy() {
    let hideEmailAddresses = !UserDefaults.standard.bool(forKey: hideEmailAddressesKey)
    UserDefaults.standard.set(hideEmailAddresses, forKey: hideEmailAddressesKey)
  }

  /// When an account lacks a ChatGPT plan name, this function supplies its reported billing type.
  private func accountTypeName(for account: BillingAccount) -> String {
    if let planName = account.planName {
      return planName
    }

    switch account.kind {
    case "apiKey":
      return "API key"
    case "amazonBedrock":
      return "Amazon Bedrock"
    case "signedOut":
      return "Signed out"
    case "unavailable":
      return "Unavailable"
    default:
      return account.kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  /// When the bulk action is selected, this function starts one pinned Desktop per saved account.
  @objc private func openAllInstances() {
    let profiles = CodexProfileManager().profiles().filter(\.hasCredentials)
    guard !profiles.isEmpty else { return }

    profileActionQueue.async { [weak self] in
      guard let self else { return }
      let profileManager = CodexProfileManager()
      var firstError: Error?

      for profile in profiles {
        do {
          try profileManager.openOrFocusInstance(for: profile)
        } catch {
          if firstError == nil {
            firstError = error
          }
        }
      }

      DispatchQueue.main.async { [weak self] in
        self?.monitor.refresh()
        if let firstError {
          self?.showError(firstError, title: "Couldn’t open every Codex instance")
        }
      }
    }
  }

  /// When an account action fails, this function presents one concise native error dialog.
  private func showError(_ error: Error, title: String) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  /// When refresh is chosen, this function requests a new local observation snapshot.
  @objc private func refresh() {
    monitor.refresh()
  }

  /// When Quit is chosen, this function terminates the menu-bar utility.
  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}
