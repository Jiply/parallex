import AppKit
import Darwin
import Foundation

struct CodexProfile: Hashable {
  let email: String
  let rootURL: URL
  let homeURL: URL
  let desktopDataURL: URL

  var authURL: URL {
    homeURL.appendingPathComponent("auth.json")
  }

  var hasCredentials: Bool {
    guard
      let values = try? authURL.resourceValues(
        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
      ),
      let attributes = try? FileManager.default.attributesOfItem(atPath: authURL.path),
      let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    else {
      return false
    }
    return
      values.isRegularFile == true
      && values.isSymbolicLink != true
      && (values.fileSize ?? 0) > 0
      && permissions == 0o600
  }
}

private struct CodexDesktopInstallation {
  let appExecutableURL: URL
  let codexExecutableURL: URL
}

private enum InstanceBoundaryStatus {
  case expected
  case mismatched
  case unknown
}

private enum CodexProfileError: LocalizedError {
  case invalidCredentialFile(String)
  case missingSharedHome(String)
  case conflictingPath(String)
  case instanceRestartFailed
  case desktopAppUnavailable
  case bundledCodexUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidCredentialFile(let path):
      return "No safe file-backed Codex credentials were found at \(path)."
    case .missingSharedHome(let path):
      return "The shared Codex home is missing at \(path). Open Codex once, then try again."
    case .conflictingPath(let path):
      return "Parallex found an incompatible item at \(path) and left it unchanged."
    case .instanceRestartFailed:
      return "The existing Codex instance could not be restarted safely. Quit it and try again."
    case .desktopAppUnavailable:
      return "Codex Desktop is not installed in Applications."
    case .bundledCodexUnavailable:
      return "The installed Codex Desktop app does not include its Codex runtime."
    }
  }
}

final class CodexProfileManager {
  private let fileManager: FileManager
  private let sharedHomeURL: URL
  private let accountsHomeURL: URL
  private let maximumCredentialBytes = 10 * 1024 * 1024
  private let sharedNames = [
    ".tmp",
    "AGENTS.md",
    "AGENTS.override.md",
    "archived_sessions",
    "attachments",
    "automations",
    "browser",
    "computer-use",
    "config.toml",
    "generated_images",
    "history.jsonl",
    "node_repl",
    "pets",
    "plugins",
    "rules",
    "sessions",
    "shell_snapshots",
    "skills",
    "state",
    "themes",
    "tmp",
    "transcription-history.jsonl",
    "vendor_imports",
    "visualizations",
    "worktrees",
  ]
  private let obsoletePrivateStateNames = [
    ".codex-global-state.json",
    ".codex-global-state.json.bak",
    ".codex-global-state.before-parallex-sharing.json",
  ]

  init(
    fileManager: FileManager = .default,
    sharedHomeURL: URL? = nil,
    accountsHomeURL: URL? = nil
  ) {
    self.fileManager = fileManager
    let userHome = fileManager.homeDirectoryForCurrentUser
    self.sharedHomeURL = sharedHomeURL
      ?? userHome.appendingPathComponent(".codex", isDirectory: true)
    self.accountsHomeURL = accountsHomeURL
      ?? userHome.appendingPathComponent(".codex-accounts", isDirectory: true)
  }

  /// When the menu opens, this function returns only structurally valid local account homes.
  func profiles() -> [CodexProfile] {
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    guard
      let accountURLs = try? fileManager.contentsOfDirectory(
        at: accountsHomeURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return accountURLs.compactMap { accountURL in
      guard
        accountURL.lastPathComponent != "backups",
        validEmail(accountURL.lastPathComponent),
        let accountValues = try? accountURL.resourceValues(forKeys: keys),
        accountValues.isDirectory == true,
        accountValues.isSymbolicLink != true
      else {
        return nil
      }

      let homeURL = accountURL.appendingPathComponent("home", isDirectory: true)
      guard
        let homeValues = try? homeURL.resourceValues(forKeys: keys),
        homeValues.isDirectory == true,
        homeValues.isSymbolicLink != true
      else {
        return nil
      }

      return CodexProfile(
        email: accountURL.lastPathComponent,
        rootURL: accountURL,
        homeURL: homeURL,
        desktopDataURL: accountURL.appendingPathComponent("desktop", isDirectory: true)
      )
    }
    .sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
  }

  /// When bulk launch includes an account, this function activates its Desktop or starts one without a chat.
  func openOrFocusInstance(for profile: CodexProfile) throws {
    if let application = runningApplication(for: profile) {
      switch instanceBoundaryStatus(application, profile: profile) {
      case .expected, .unknown:
        application.activate(options: [.activateAllWindows])
        return
      case .mismatched:
        let installation = try validatedInstallation(for: profile)
        try validateInstancePreparation(profile, codexExecutableURL: installation.codexExecutableURL)
        try terminateStaleInstance(application)
        try launchInstance(profile, installation: installation)
        return
      }
    }

    let installation = try validatedInstallation(for: profile)
    try validateInstancePreparation(profile, codexExecutableURL: installation.codexExecutableURL)
    try launchInstance(profile, installation: installation)
  }

  /// When a validated account is ready, this function prepares and starts its Desktop process.
  private func launchInstance(
    _ profile: CodexProfile,
    installation: CodexDesktopInstallation
  ) throws {
    try prepareInstance(profile, codexExecutableURL: installation.codexExecutableURL)
    let cliWrapperURL = profile.rootURL.appendingPathComponent(".parallex-codex")

    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = sharedHomeURL.path
    environment["CODEX_SQLITE_HOME"] = sharedHomeURL.path
    environment["CODEX_ELECTRON_USER_DATA_PATH"] = profile.desktopDataURL.path
    environment["CODEX_CLI_PATH"] = cliWrapperURL.path

    let process = Process()
    process.executableURL = installation.appExecutableURL
    process.arguments = ["--user-data-dir=\(profile.desktopDataURL.path)"]
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }

  /// When a Desktop needs to launch, this function validates credentials and the installed runtime first.
  private func validatedInstallation(for profile: CodexProfile) throws -> CodexDesktopInstallation {
    guard profile.hasCredentials else {
      throw CodexProfileError.invalidCredentialFile(profile.authURL.path)
    }
    guard let installation = desktopInstallation() else {
      throw CodexProfileError.desktopAppUnavailable
    }
    guard fileManager.isExecutableFile(atPath: installation.codexExecutableURL.path) else {
      throw CodexProfileError.bundledCodexUnavailable
    }
    return installation
  }

  /// When a profile instance starts, this function prepares only its local runtime boundary.
  func prepareInstance(_ profile: CodexProfile, codexExecutableURL: URL) throws {
    guard
      let sharedValues = try? sharedHomeURL.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      ),
      sharedValues.isDirectory == true,
      sharedValues.isSymbolicLink != true
    else {
      throw CodexProfileError.missingSharedHome(sharedHomeURL.path)
    }

    try createPrivateDirectory(at: accountsHomeURL)
    try createPrivateDirectory(at: profile.rootURL)
    try createPrivateDirectory(at: profile.homeURL)
    try validateCredential(at: profile.authURL)
    try createPrivateDirectory(at: profile.desktopDataURL)

    try removeVerifiedLegacyGlobalStateCopies(in: profile.homeURL)

    for name in sharedNames {
      try ensureSharedLink(named: name, in: profile.homeURL)
    }

    let sharedEntries = try fileManager.contentsOfDirectory(
      at: sharedHomeURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    for entry in sharedEntries where entry.lastPathComponent.hasSuffix(".config.toml") {
      try ensureSharedLink(named: entry.lastPathComponent, in: profile.homeURL)
    }

    try installCLIWrapper(for: profile, codexExecutableURL: codexExecutableURL)
  }

  /// When a directory name represents an account, this function accepts safe common email syntax.
  private func validEmail(_ email: String) -> Bool {
    let pieces = email.split(separator: "@", omittingEmptySubsequences: false)
    guard
      email == email.lowercased(),
      email.utf8.count <= 254,
      pieces.count == 2,
      let localPart = pieces.first,
      let domainPart = pieces.last
    else {
      return false
    }

    let localAllowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.!#$%&'*+-=?^_`{|}~"
    )
    let localIsValid =
      !localPart.isEmpty
      && localPart.utf8.count <= 64
      && localPart.first != "."
      && localPart.last != "."
      && !localPart.contains("..")
      && localPart.unicodeScalars.allSatisfy(localAllowed.contains)
    guard localIsValid else { return false }

    let domainAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    let labels = domainPart.split(separator: ".", omittingEmptySubsequences: false)
    return
      domainPart.utf8.count <= 253
      && labels.count >= 2
      && labels.allSatisfy { label in
        !label.isEmpty
          && label.utf8.count <= 63
          && label.first != "-"
          && label.last != "-"
          && label.unicodeScalars.allSatisfy(domainAllowed.contains)
      }
  }

  /// When credentials gate an instance, this function validates metadata without reading token bytes.
  private func validateCredential(at url: URL) throws {
    guard
      let values = try? url.resourceValues(
        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
      ),
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let fileSize = values.fileSize,
      fileSize > 0,
      fileSize <= maximumCredentialBytes,
      permissions == 0o600
    else {
      throw CodexProfileError.invalidCredentialFile(url.path)
    }
  }

  /// When a profile directory is needed, this function creates it with owner-only permissions.
  private func createPrivateDirectory(at url: URL) throws {
    if pathExistsIncludingSymbolicLink(url) {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CodexProfileError.conflictingPath(url.path)
      }
    }

    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: url.path
    )
  }

  /// When shared Codex state exists, this function links it without deleting divergent data.
  private func ensureSharedLink(named name: String, in accountHomeURL: URL) throws {
    let sourceURL = sharedHomeURL.appendingPathComponent(name)
    guard pathExistsIncludingSymbolicLink(sourceURL) else { return }

    let targetURL = accountHomeURL.appendingPathComponent(name)
    if let destination = try? fileManager.destinationOfSymbolicLink(atPath: targetURL.path) {
      let destinationURL = URL(
        fileURLWithPath: destination,
        relativeTo: targetURL.deletingLastPathComponent()
      ).standardizedFileURL
      guard
        destinationURL.resolvingSymlinksInPath().path
          == sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
      else {
        throw CodexProfileError.conflictingPath(targetURL.path)
      }
      return
    }

    guard !pathExistsIncludingSymbolicLink(targetURL) else {
      throw CodexProfileError.conflictingPath(targetURL.path)
    }
    try fileManager.createSymbolicLink(at: targetURL, withDestinationURL: sourceURL)
  }

  /// When launch is preflighted, this function accepts only an absent or correct shared link.
  private func validateSharedLinkTarget(named name: String, in accountHomeURL: URL) throws {
    let sourceURL = sharedHomeURL.appendingPathComponent(name)
    guard pathExistsIncludingSymbolicLink(sourceURL) else { return }

    let targetURL = accountHomeURL.appendingPathComponent(name)
    guard pathExistsIncludingSymbolicLink(targetURL) else { return }
    guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: targetURL.path) else {
      throw CodexProfileError.conflictingPath(targetURL.path)
    }
    let destinationURL = URL(
      fileURLWithPath: destination,
      relativeTo: targetURL.deletingLastPathComponent()
    ).standardizedFileURL
    guard
      destinationURL.resolvingSymlinksInPath().path
        == sourceURL.standardizedFileURL.resolvingSymlinksInPath().path
    else {
      throw CodexProfileError.conflictingPath(targetURL.path)
    }
  }

  /// When an old Parallex layout left global-state copies, this removes only byte-identical copies.
  private func removeVerifiedLegacyGlobalStateCopies(in accountHomeURL: URL) throws {
    for staleURL in try verifiedLegacyGlobalStateCopies(in: accountHomeURL) {
      try fileManager.removeItem(at: staleURL)
    }
  }

  /// When old global state exists, this validates that removing it cannot discard divergent bytes.
  private func validateLegacyGlobalStateCopies(in accountHomeURL: URL) throws {
    _ = try verifiedLegacyGlobalStateCopies(in: accountHomeURL)
  }

  /// When old global state exists, this returns only copies proven identical to canonical state.
  private func verifiedLegacyGlobalStateCopies(in accountHomeURL: URL) throws -> [URL] {
    let canonicalURL = sharedHomeURL.appendingPathComponent(".codex-global-state.json")
    let staleURLs = obsoletePrivateStateNames
      .map { accountHomeURL.appendingPathComponent($0) }
      .filter(pathExistsIncludingSymbolicLink)
    guard !staleURLs.isEmpty else { return [] }

    guard
      let canonicalValues = try? canonicalURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      ),
      canonicalValues.isRegularFile == true,
      canonicalValues.isSymbolicLink != true,
      let canonicalData = fileManager.contents(atPath: canonicalURL.path),
      !canonicalData.isEmpty,
      (try? JSONSerialization.jsonObject(with: canonicalData)) is [String: Any]
    else {
      throw CodexProfileError.conflictingPath(canonicalURL.path)
    }

    for staleURL in staleURLs {
      if let destination = try? fileManager.destinationOfSymbolicLink(atPath: staleURL.path) {
        let destinationURL = URL(
          fileURLWithPath: destination,
          relativeTo: staleURL.deletingLastPathComponent()
        ).standardizedFileURL
        guard
          destinationURL.resolvingSymlinksInPath().path
            == canonicalURL.standardizedFileURL.resolvingSymlinksInPath().path
        else {
          throw CodexProfileError.conflictingPath(staleURL.path)
        }
      } else {
        guard fileManager.contents(atPath: staleURL.path) == canonicalData else {
          throw CodexProfileError.conflictingPath(staleURL.path)
        }
      }
    }

    return staleURLs
  }

  /// When the Desktop spawns Codex, this function pins that process to the profile credential.
  private func installCLIWrapper(for profile: CodexProfile, codexExecutableURL: URL) throws {
    let wrapperURL = profile.rootURL.appendingPathComponent(".parallex-codex")
    let marker = "#!/bin/zsh\n# Generated by Parallex."
    try validateGeneratedWrapper(at: wrapperURL)

    let script = """
    \(marker)
    set -euo pipefail
    export CODEX_HOME=\(shellQuote(profile.homeURL.path))

    exec \(shellQuote(codexExecutableURL.path)) \\
      -c \(shellQuote("cli_auth_credentials_store=file")) \\
      -c \(shellQuote("sqlite_home=\(sharedHomeURL.path)")) \\
      -c \(shellQuote("forced_login_method=chatgpt")) \\
      "$@"
    """
    try Data(script.utf8).write(to: wrapperURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: wrapperURL.path
    )
  }

  /// When a generated shim already exists, this function rejects user-owned or oversized files.
  private func validateGeneratedWrapper(at wrapperURL: URL) throws {
    guard pathExistsIncludingSymbolicLink(wrapperURL) else { return }
    let marker = "#!/bin/zsh\n# Generated by Parallex."
    let values = try wrapperURL.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      (values.fileSize ?? Int.max) <= 16 * 1024,
      let existingData = fileManager.contents(atPath: wrapperURL.path),
      String(decoding: existingData.prefix(marker.utf8.count), as: UTF8.self) == marker
    else {
      throw CodexProfileError.conflictingPath(wrapperURL.path)
    }
  }

  /// When an account already has a Desktop, this function finds only that exact local instance.
  private func runningApplication(for profile: CodexProfile) -> NSRunningApplication? {
    let expectedDesktopPath = profile.desktopDataURL.standardizedFileURL.path

    return NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
      .first { application in
        guard let data = processArguments(for: application.processIdentifier) else { return false }
        guard let desktopPath = processValue(prefixedBy: "--user-data-dir=", in: data) else {
          return false
        }
        return URL(fileURLWithPath: desktopPath).standardizedFileURL.path == expectedDesktopPath
      }
  }

  /// When a matching Desktop is already open, this function classifies its inspectable boundary.
  private func instanceBoundaryStatus(
    _ application: NSRunningApplication,
    profile: CodexProfile
  ) -> InstanceBoundaryStatus {
    guard let data = processArguments(for: application.processIdentifier) else { return .unknown }
    let expectedWrapper = profile.rootURL.appendingPathComponent(".parallex-codex").path
    let matches =
      processValue(prefixedBy: "CODEX_HOME=", in: data) == sharedHomeURL.path
      && processValue(prefixedBy: "CODEX_SQLITE_HOME=", in: data) == sharedHomeURL.path
      && processValue(prefixedBy: "CODEX_ELECTRON_USER_DATA_PATH=", in: data)
        == profile.desktopDataURL.path
      && processValue(prefixedBy: "CODEX_CLI_PATH=", in: data) == expectedWrapper
    return matches ? .expected : .mismatched
  }

  /// When a stale instance may need replacement, this validates every mutation target read-only.
  private func validateInstancePreparation(
    _ profile: CodexProfile,
    codexExecutableURL: URL
  ) throws {
    guard
      let sharedValues = try? sharedHomeURL.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      ),
      sharedValues.isDirectory == true,
      sharedValues.isSymbolicLink != true
    else {
      throw CodexProfileError.missingSharedHome(sharedHomeURL.path)
    }

    try validateCredential(at: profile.authURL)
    for directoryURL in [accountsHomeURL, profile.rootURL, profile.homeURL, profile.desktopDataURL]
    where pathExistsIncludingSymbolicLink(directoryURL) {
      let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw CodexProfileError.conflictingPath(directoryURL.path)
      }
    }

    for name in sharedNames {
      try validateSharedLinkTarget(named: name, in: profile.homeURL)
    }
    let sharedEntries = try fileManager.contentsOfDirectory(
      at: sharedHomeURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    for entry in sharedEntries where entry.lastPathComponent.hasSuffix(".config.toml") {
      try validateSharedLinkTarget(named: entry.lastPathComponent, in: profile.homeURL)
    }

    guard fileManager.isExecutableFile(atPath: codexExecutableURL.path) else {
      throw CodexProfileError.bundledCodexUnavailable
    }
    try validateGeneratedWrapper(at: profile.rootURL.appendingPathComponent(".parallex-codex"))
    try validateLegacyGlobalStateCopies(in: profile.homeURL)
  }

  /// When an older Parallex boundary is detected, this function closes it before migration.
  private func terminateStaleInstance(_ application: NSRunningApplication) throws {
    let processID = application.processIdentifier
    if !application.terminate() {
      kill(processID, SIGTERM)
    }

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if kill(processID, 0) != 0, errno != EPERM {
        return
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw CodexProfileError.instanceRestartFailed
  }

  /// When macOS exposes a same-user process, this function reads its argument buffer transiently.
  private func processArguments(for processID: pid_t) -> Data? {
    var keys: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
    let keyCount = UInt32(keys.count)
    var size = 0

    let sizeResult = keys.withUnsafeMutableBufferPointer { pointer in
      sysctl(pointer.baseAddress, keyCount, nil, &size, nil, 0)
    }
    guard sizeResult == 0, size > MemoryLayout<Int32>.size else { return nil }

    var bytes = [UInt8](repeating: 0, count: size)
    let readResult = keys.withUnsafeMutableBufferPointer { pointer in
      bytes.withUnsafeMutableBytes { buffer in
        sysctl(pointer.baseAddress, keyCount, buffer.baseAddress, &size, nil, 0)
      }
    }
    guard readResult == 0 else { return nil }
    return Data(bytes.prefix(size))
  }

  /// When a process buffer is available, this function finds one exact argument or environment value.
  private func processValue(prefixedBy prefix: String, in data: Data) -> String? {
    let bytes = [UInt8](data)
    let needle = [UInt8](prefix.utf8)
    guard !needle.isEmpty, bytes.count >= needle.count else { return nil }

    for index in 0...(bytes.count - needle.count) {
      guard index == 0 || bytes[index - 1] == 0 else { continue }
      guard bytes[index..<(index + needle.count)].elementsEqual(needle) else { continue }

      let valueStart = index + needle.count
      let valueEnd = bytes[valueStart...].firstIndex(of: 0) ?? bytes.endIndex
      guard valueEnd > valueStart else { return nil }
      return String(bytes: bytes[valueStart..<valueEnd], encoding: .utf8)
    }
    return nil
  }

  /// When a generated shell command contains a path, this function quotes it as one literal word.
  private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  /// When a desktop instance starts, this function locates the installed application and runtime.
  private func desktopInstallation() -> CodexDesktopInstallation? {
    let bundleURLs = [
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
      URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true),
      URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true),
    ]

    for bundleURL in bundleURLs.compactMap({ $0 }) {
      guard
        let bundle = Bundle(url: bundleURL),
        let appExecutableURL = bundle.executableURL,
        let resourcesURL = bundle.resourceURL,
        fileManager.isExecutableFile(atPath: appExecutableURL.path)
      else {
        continue
      }
      return CodexDesktopInstallation(
        appExecutableURL: appExecutableURL,
        codexExecutableURL: resourcesURL.appendingPathComponent("codex")
      )
    }
    return nil
  }

  /// When FileManager follows a broken link, this function still recognizes the path as occupied.
  private func pathExistsIncludingSymbolicLink(_ url: URL) -> Bool {
    fileManager.fileExists(atPath: url.path)
      || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }
}
