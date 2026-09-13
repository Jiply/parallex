import Darwin
import Foundation

private let relayNotification = Notification.Name("org.curvelabs.Parallex.codex-thread-event")
private let relayableMethods = Set([
  "thread/name/updated"
])

@main
enum CodexEventRelay {
  /// When Codex Desktop starts its app-server, this function proxies stdio and shares sidebar events.
  static func main() {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var authHome: String?
    var sharedHome: String?
    while arguments.first == "--auth-home" || arguments.first == "--shared-home" {
      guard arguments.count > 1 else { exit(64) }
      let option = arguments.removeFirst()
      let value = arguments.removeFirst()
      if option == "--auth-home" { authHome = value } else { sharedHome = value }
    }
    guard let executable = arguments.first else {
      FileHandle.standardError.write(Data("Missing Codex executable.\n".utf8))
      exit(64)
    }

    do {
      exit(
        try run(
          executable: executable, arguments: Array(arguments.dropFirst()),
          authHome: authHome, sharedHome: sharedHome))
    } catch {
      FileHandle.standardError.write(
        Data("Codex relay failed: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  /// When the child app-server runs, this function preserves its protocol while relaying thread events.
  private static func run(
    executable: String, arguments: [String], authHome: String?,
    sharedHome: String?
  ) throws -> Int32 {
    let process = Process()
    let childInput = Pipe()
    let childOutput = Pipe()
    let outputQueue = DispatchQueue(label: "org.curvelabs.Parallex.codex-relay-output")
    let sourceID = UUID().uuidString
    let outputDrained = DispatchGroup()
    outputDrained.enter()
    var outputClosed = false
    var parseBuffer = Data()
    var scanOffset = parseBuffer.startIndex
    var inputBuffer = Data()
    var credentialBridge: CodexCredentialBridge?

    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
    if let authHome, let sharedHome, arguments.contains("app-server") {
      process.arguments =
        arguments + [
          "-c", "cli_auth_credentials_store=ephemeral",
          "-c", "thread_unload_delay_secs=0",
        ]
      if let browser = CodexBrowserConfiguration(
        executable: executable,
        authHome: authHome, sharedHome: sharedHome)
      {
        process.arguments! += browser.arguments
      }
      process.environment?["CODEX_HOME"] = sharedHome
      process.environment?["CODEX_SQLITE_HOME"] = sharedHome
      credentialBridge = try CodexCredentialBridge(
        executable: executable,
        authHome: authHome, sharedHome: sharedHome, queue: outputQueue,
        write: { childInput.fileHandleForWriting.write($0) },
        emit: { FileHandle.standardOutput.write($0) })
    }
    process.standardInput = childInput
    process.standardOutput = childOutput
    process.standardError = FileHandle.standardError

    let notificationCenter = DistributedNotificationCenter.default()
    let observer = notificationCenter.addObserver(
      forName: relayNotification,
      object: nil,
      queue: nil
    ) { notification in
      guard
        notification.userInfo?["source"] as? String != sourceID,
        let message = notification.userInfo?["message"] as? String,
        let data = message.data(using: .utf8),
        relayableMethod(in: data) != nil
      else {
        return
      }
      outputQueue.async {
        guard !outputClosed else { return }
        FileHandle.standardOutput.write(data)
        if data.last != 0x0A { FileHandle.standardOutput.write(Data([0x0A])) }
      }
    }

    FileHandle.standardInput.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      outputQueue.async {
        guard let bridge = credentialBridge else {
          if data.isEmpty {
            try? childInput.fileHandleForWriting.close()
          } else {
            childInput.fileHandleForWriting.write(data)
          }
          return
        }
        if data.isEmpty {
          if !inputBuffer.isEmpty { bridge.receiveInput(inputBuffer) }
          try? childInput.fileHandleForWriting.close()
          return
        }
        inputBuffer.append(data)
        while let newline = inputBuffer.firstIndex(of: 0x0A) {
          let line = Data(inputBuffer[...newline])
          inputBuffer.removeSubrange(...newline)
          bridge.receiveInput(line)
        }
      }
    }

    childOutput.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
      }
      outputQueue.async {
        if data.isEmpty {
          outputClosed = true
          if !parseBuffer.isEmpty { FileHandle.standardOutput.write(parseBuffer) }
          outputDrained.leave()
          return
        }
        parseBuffer.append(data)

        // Scan each byte once and serialize whole lines so foreign events cannot split a response.
        while let newline = parseBuffer[scanOffset...].firstIndex(of: 0x0A) {
          let line = Data(parseBuffer[...newline])
          parseBuffer.removeSubrange(...newline)
          scanOffset = parseBuffer.startIndex
          if let bridge = credentialBridge {
            bridge.receiveOutput(line)
          } else {
            FileHandle.standardOutput.write(line)
          }
          guard relayableMethod(in: line) != nil else { continue }
          notificationCenter.postNotificationName(
            relayNotification,
            object: nil,
            userInfo: [
              "source": sourceID,
              "message": String(decoding: line, as: UTF8.self),
            ],
            deliverImmediately: true
          )
        }
        scanOffset = parseBuffer.endIndex
      }
    }

    try process.run()
    while process.isRunning || outputDrained.wait(timeout: .now()) != .success {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    FileHandle.standardInput.readabilityHandler = nil
    childOutput.fileHandleForReading.readabilityHandler = nil
    notificationCenter.removeObserver(observer)
    outputQueue.sync { credentialBridge?.stop() }
    return process.terminationStatus
  }

  /// When a protocol line is observed, this function accepts only sidebar-changing notifications.
  private static func relayableMethod(in data: Data) -> String? {
    guard
      data.count <= 1024 * 1024,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["id"] == nil,
      let method = object["method"] as? String,
      relayableMethods.contains(method),
      object["params"] is [String: Any]
    else {
      return nil
    }
    return method
  }
}

/// When Desktop builds browser settings, this keeps its runtime and account paths valid across homes.
private struct CodexBrowserConfiguration {
  let command: String
  let environment: [String: String]

  init?(executable: String, authHome: String, sharedHome: String) {
    let resources = URL(fileURLWithPath: executable).deletingLastPathComponent()
    let browser = resources.appendingPathComponent("plugins/openai-bundled/plugins/browser")
    let service = browser.appendingPathComponent("scripts/browser-service.mjs")
    let node = resources.appendingPathComponent("cua_node")
    let modules = node.appendingPathComponent("lib/node_modules")
    command = node.appendingPathComponent("bin/node_repl").path
    guard FileManager.default.isExecutableFile(atPath: command),
      FileManager.default.fileExists(atPath: service.path),
      let manifest = try? Data(
        contentsOf: browser.appendingPathComponent(".codex-plugin/plugin.json")),
      let plugin = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
      let version = plugin["version"] as? String
    else { return nil }
    let home = URL(fileURLWithPath: authHome)
    let trust = [home, URL(fileURLWithPath: sharedHome), modules, browser]
      .map { $0.resolvingSymlinksInPath().path }.joined(separator: ":")
    let services = ["browser": service.path, "sky": "@oai/sky/service"]
    guard
      let serviceData = try? JSONSerialization.data(
        withJSONObject: services,
        options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    environment = [
      "CODEX_HOME": authHome,
      "CODEX_CLI_PATH": home.deletingLastPathComponent().appendingPathComponent(".parallex-codex")
        .path,
      "NODE_REPL_TRUSTED_CODE_PATHS": trust,
      "NODE_REPL_TRUSTED_SERVICES": String(decoding: serviceData, as: UTF8.self),
      "NODE_REPL_NODE_MODULE_DIRS": modules.path,
      "NODE_REPL_NODE_PATH": node.appendingPathComponent("bin/node").path,
      "BROWSER_USE_CODEX_APP_VERSION": version,
    ]
  }

  var arguments: [String] {
    let values =
      environment.map { ("mcp_servers.node_repl.env." + $0.key, $0.value) }
      + [("mcp_servers.node_repl.command", command)]
    return values.sorted { $0.0 < $1.0 }.flatMap { key, value in
      let json = try! JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .withoutEscapingSlashes])
      return ["-c", key + "=" + String(decoding: json, as: UTF8.self)]
    }
  }

  func definition(_ value: Any) -> Any {
    guard var definition = value as? [String: Any] else { return value }
    // Keep native instructions, pipe settings, flags and any unrelated server configuration.
    var env = definition["env"] as? [String: String] ?? [:]
    let services = env["NODE_REPL_TRUSTED_SERVICES"]
    env.merge(environment) { _, current in current }
    // Package services belong to the app's native runtime; retain that supported variant.
    if let services, services.contains("@oai/browser-desktop/service") {
      env["NODE_REPL_TRUSTED_SERVICES"] = services
    }
    definition["env"] = env
    definition["command"] = command
    return definition
  }

  func normalize(_ data: Data) -> Data {
    guard var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      var params = message["params"] as? [String: Any]
    else { return data }
    var changed = false
    if var config = params["config"] as? [String: Any],
      let value = config["mcp_servers.node_repl"]
    {
      config["mcp_servers.node_repl"] = definition(value)
      params["config"] = config
      changed = true
    }
    if message["method"] as? String == "config/batchWrite",
      var edits = params["edits"] as? [[String: Any]]
    {
      for index in edits.indices where edits[index]["keyPath"] as? String == "mcp_servers.node_repl"
      {
        if let value = edits[index]["value"] {
          edits[index]["value"] = definition(value)
          changed = true
        }
      }
      params["edits"] = edits
    }
    guard changed else { return data }
    message["params"] = params
    guard
      var normalized = try? JSONSerialization.data(
        withJSONObject: message,
        options: [.withoutEscapingSlashes])
    else { return data }
    normalized.append(0x0A)
    return normalized
  }
}

/// When accounts share local storage, this bridge keeps their runtime credentials in process memory.
private final class CodexCredentialBridge {
  private let helper = Process()
  private let helperInput = Pipe()
  private let helperOutput = Pipe()
  private let authHome: String
  private let sharedHome: String
  private let browserConfiguration: CodexBrowserConfiguration?
  private let queue: DispatchQueue
  private let write: (Data) -> Void
  private let emit: (Data) -> Void
  private var helperBuffer = Data()
  private var pendingInput: [Data] = []
  private var pendingOutput: [Data] = []
  private var pendingHelper: [[String: Any]] = []
  private var helperRequests: [String: [String: Any]] = [:]
  private var hiddenRequests = Set<String>()
  private var initializeID: Any?
  private var initializeResponse: Data?
  private var authInitializeID: String?
  private var ready = false
  private var helperReady = false
  private var helperUnavailable = false
  private var stopped = false
  private let helperInitializeID = "parallex-auth-initialize-" + UUID().uuidString
  private let sourceID = UUID().uuidString
  private let ownershipNotification = Notification.Name(
    "org.curvelabs.Parallex.codex-thread-ownership")
  private var ownershipObserver: NSObjectProtocol?
  private var idleThreads = Set<String>()
  private var loadedThreads = Set<String>()
  private var resumeRequests: [String: Data] = [:]
  private var resumeTemplates: [String: [String: Any]] = [:]
  private var startingRequests: [String: [String: Any]] = [:]
  private var pendingTurns: [String: String] = [:]
  private var releasedThreads = Set<String>()
  private var recoveringTurns: [String: Data] = [:]
  private var resumeAttempts = Set<String>()
  private var handoffs: [String: (request: Data, threadID: String)] = [:]
  private var releases: [String: [String: String]] = [:]
  private var releasePendingInput: [String: [Data]] = [:]

  init(
    executable: String, authHome: String, sharedHome: String, queue: DispatchQueue,
    write: @escaping (Data) -> Void, emit: @escaping (Data) -> Void
  ) throws {
    self.authHome = authHome
    self.sharedHome = sharedHome
    self.browserConfiguration = CodexBrowserConfiguration(
      executable: executable,
      authHome: authHome, sharedHome: sharedHome)
    self.queue = queue
    self.write = write
    self.emit = emit
    helper.executableURL = URL(fileURLWithPath: executable)
    helper.arguments = [
      "-c", "cli_auth_credentials_store=file", "-c",
      "sqlite_home=\(sharedHome)", "-c", "forced_login_method=chatgpt",
      "-c", "features.plugins=false", "-c", "features.remote_plugin=false",
      "-c", "features.apps=false", "app-server", "--stdio",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = authHome
    environment["CODEX_SQLITE_HOME"] = sharedHome
    helper.environment = environment
    helper.standardInput = helperInput
    _ = fcntl(helperInput.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    helper.standardOutput = helperOutput
    helper.standardError = FileHandle.nullDevice
    helperOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      queue.async {
        guard let self, !self.stopped else { return }
        self.helperBuffer.append(data)
        while let newline = self.helperBuffer.firstIndex(of: 0x0A) {
          let line = Data(self.helperBuffer[...newline])
          self.helperBuffer.removeSubrange(...newline)
          if let message = self.object(line) { self.receiveHelper(message) }
        }
        if data.isEmpty {
          self.failHelper()
        }
      }
    }
    try helper.run()
    sendHelper([
      "id": helperInitializeID, "method": "initialize",
      "params": [
        "clientInfo": ["name": "parallex_auth", "version": "1"],
        "capabilities": ["experimentalApi": true],
      ],
    ])
    ownershipObserver = DistributedNotificationCenter.default().addObserver(
      forName: ownershipNotification, object: sharedHome, queue: nil
    ) { [weak self] notification in
      guard let message = notification.userInfo as? [String: String] else { return }
      queue.async { self?.receiveOwnership(message) }
    }
  }

  func stop() {
    stopped = true
    if let ownershipObserver {
      DistributedNotificationCenter.default().removeObserver(ownershipObserver)
    }
    helperOutput.fileHandleForReading.readabilityHandler = nil
    try? helperInput.fileHandleForWriting.close()
    if helper.isRunning { helper.terminate() }
  }

  /// When a client reads or changes credentials, this function uses the profile's native auth process.
  func receiveInput(_ data: Data) {
    let data = browserConfiguration?.normalize(data) ?? data
    guard var message = object(data) else {
      write(data)
      return
    }
    let method = message["method"] as? String
    if method == "initialize" {
      initializeID = message["id"]
      var params = message["params"] as? [String: Any] ?? [:]
      var capabilities = params["capabilities"] as? [String: Any] ?? [:]
      capabilities["experimentalApi"] = true
      if let excluded = capabilities["optOutNotificationMethods"] as? [String] {
        capabilities["optOutNotificationMethods"] = excluded.filter {
          $0 != "thread/closed" && $0 != "thread/status/changed"
        }
      }
      params["capabilities"] = capabilities
      message["params"] = params
      send(message)
      return
    }
    // The bridge initializes the runtime before supplying its in-memory account.
    if method == "initialized" { return }
    guard ready else {
      pendingInput.append(data)
      return
    }
    let params = message["params"] as? [String: Any]
    let startsWork =
      method == "turn/start" || method == "thread/compact/start"
      || method == "thread/shellCommand"
    if let threadID = params?["threadId"] as? String, startsWork,
      releases.values.contains(where: { $0["thread"] == threadID })
    {
      releasePendingInput[threadID, default: []].append(data)
      queue.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard let self else { return }
        for input in self.releasePendingInput.removeValue(forKey: threadID) ?? [] {
          if let request = self.object(input) {
            self.fail(
              request,
              message:
                "This task is still switching between account instances. Try again when its active work finishes."
            )
          }
        }
      }
      return
    }
    if let threadID = params?["threadId"] as? String, startsWork,
      releasedThreads.contains(threadID), var resume = resumeTemplates[threadID]
    {
      let id = "parallex-recover-" + UUID().uuidString
      hiddenRequests.insert(id)
      recoveringTurns[id] = data
      resume["threadId"] = threadID
      resume["excludeTurns"] = true
      receiveInput(encoded(["id": id, "method": "thread/resume", "params": resume]))
      return
    }
    if let id = message["id"], method == "thread/resume" {
      resumeRequests[String(describing: id)] = data
    }
    if let id = message["id"], let params, method == "thread/start" || method == "thread/resume" {
      startingRequests[String(describing: id)] = params
    }
    if let id = message["id"], let threadID = params?["threadId"] as? String, startsWork {
      pendingTurns[String(describing: id)] = threadID
      idleThreads.remove(threadID)
    }
    if [
      "getAuthStatus", "account/read", "account/login/start", "account/login/cancel",
      "account/logout",
    ].contains(method ?? "") {
      guard !helperUnavailable, helper.isRunning else {
        fail(message, message: "The account credential process stopped. Reopen this instance.")
        return
      }
      let id = "parallex-auth-" + UUID().uuidString
      helperRequests[id] = message
      message["id"] = id
      if helperReady { sendHelper(message) } else { pendingHelper.append(message) }
      return
    }
    write(data)
  }

  /// When the runtime initializes, this function installs the selected account before exposing readiness.
  func receiveOutput(_ data: Data) {
    guard let message = object(data) else {
      emit(data)
      return
    }
    observeThread(message)
    if let id = message["id"] { pendingTurns.removeValue(forKey: String(describing: id)) }
    if let id = message["id"],
      let requested = startingRequests.removeValue(forKey: String(describing: id)),
      let thread = (message["result"] as? [String: Any])?["thread"] as? [String: Any],
      let threadID = thread["id"] as? String
    {
      let fields = Set([
        "approvalPolicy", "approvalsReviewer", "baseInstructions", "config", "cwd",
        "developerInstructions", "model", "modelProvider", "permissions", "personality",
        "runtimeWorkspaceRoots", "sandbox", "serviceTier",
      ])
      resumeTemplates[threadID] = requested.filter { fields.contains($0.key) }
      releasedThreads.remove(threadID)
    }
    if let id = message["id"],
      let request = resumeRequests.removeValue(forKey: String(describing: id))
    {
      let key = String(describing: id)
      let error = (message["error"] as? [String: Any])?["message"] as? String ?? ""
      if error.contains("already has an active writer"), !resumeAttempts.contains(key),
        let params = object(request)?["params"] as? [String: Any],
        let threadID = params["threadId"] as? String
      {
        resumeAttempts.insert(key)
        let handoffID = UUID().uuidString
        handoffs[handoffID] = (request, threadID)
        postOwnership(["action": "request", "request": handoffID, "thread": threadID])
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
          self?.finishHandoff(handoffID, released: false)
        }
        return
      }
      resumeAttempts.remove(key)
    }
    if let id = message["id"], let initializeID,
      String(describing: id) == String(describing: initializeID)
    {
      self.initializeID = nil
      guard message["error"] == nil else {
        emit(data)
        return
      }
      initializeResponse = data
      send(["method": "initialized", "params": [:]])
      authInitializeID = installCredential()
      if authInitializeID == nil { finishInitialization() }
      return
    }
    if let id = message["id"] as? String, hiddenRequests.remove(id) != nil {
      if id == authInitializeID { finishInitialization() }
      if message["error"] != nil, let release = releases.removeValue(forKey: id),
        let threadID = release["thread"]
      {
        postOwnership([
          "action": "busy", "request": release["request"] ?? "",
          "thread": threadID, "target": release["source"] ?? "",
        ])
        for input in releasePendingInput.removeValue(forKey: threadID) ?? [] { receiveInput(input) }
      }
      if let pendingTurn = recoveringTurns.removeValue(forKey: id) {
        if let error = message["error"], let originalID = object(pendingTurn)?["id"] {
          emit(encoded(["id": originalID, "error": error]))
        } else {
          receiveInput(pendingTurn)
        }
      }
      return
    }
    if message["method"] as? String == "account/chatgptAuthTokens/refresh",
      message["id"] != nil
    {
      guard !helperUnavailable, helper.isRunning else {
        fail(message, message: "The account credential process stopped. Reopen this instance.")
        return
      }
      let id = "parallex-refresh-" + UUID().uuidString
      helperRequests[id] = message
      let request: [String: Any] = [
        "id": id, "method": "account/read",
        "params": ["refreshToken": true],
      ]
      if helperReady { sendHelper(request) } else { pendingHelper.append(request) }
      return
    }
    if ready { emit(data) } else { pendingOutput.append(data) }
  }

  /// When the private auth process responds, this function forwards public results and refreshes memory.
  private func receiveHelper(_ message: [String: Any]) {
    if message["id"] as? String == helperInitializeID {
      guard message["error"] == nil else {
        failHelper()
        if helper.isRunning { helper.terminate() }
        return
      }
      helperReady = true
      sendHelper(["method": "initialized", "params": [:]])
      let requests = pendingHelper
      pendingHelper.removeAll()
      for request in requests { sendHelper(request) }
      return
    }
    if let id = message["id"] as? String, let request = helperRequests.removeValue(forKey: id) {
      if request["method"] as? String == "account/chatgptAuthTokens/refresh" {
        let previousAccountID =
          (request["params"] as? [String: Any])?["previousAccountId"] as? String
        guard message["error"] == nil, let credential = credential(),
          previousAccountID == nil || previousAccountID == credential["chatgptAccountId"] as? String
        else {
          fail(request, message: "This billing account needs to sign in again.")
          return
        }
        var result = credential
        result.removeValue(forKey: "type")
        send(["id": request["id"]!, "result": result])
        return
      }
      if message["error"] == nil, request["method"] as? String == "account/logout" {
        clearCredential()
      }
      if message["error"] == nil,
        ["getAuthStatus", "account/read"].contains(request["method"] as? String ?? ""),
        (request["params"] as? [String: Any])?["refreshToken"] as? Bool == true
      {
        _ = installCredential()
      }
      var response = message
      response["id"] = request["id"]
      emit(encoded(response))
      return
    }
    if message["method"] as? String == "account/login/completed" {
      if (message["params"] as? [String: Any])?["success"] as? Bool == true {
        _ = installCredential()
      }
      emit(encoded(message))
    }
  }

  private func finishInitialization() {
    ready = true
    if let initializeResponse { emit(initializeResponse) }
    initializeResponse = nil
    let notifications = pendingOutput
    pendingOutput.removeAll()
    for notification in notifications { emit(notification) }
    let requests = pendingInput
    pendingInput.removeAll()
    for request in requests { receiveInput(request) }
  }

  /// When another account needs an idle task, this function waits for the runtime to close its writer.
  private func receiveOwnership(_ message: [String: String]) {
    guard !stopped, message["source"] != sourceID, let threadID = message["thread"],
      let requestID = message["request"]
    else { return }
    if message["action"] == "request" {
      guard loadedThreads.contains(threadID) else { return }
      guard resumeTemplates[threadID] != nil, !pendingTurns.values.contains(threadID),
        idleThreads.remove(threadID) != nil
      else {
        postOwnership([
          "action": "busy", "request": requestID, "thread": threadID,
          "target": message["source"] ?? "",
        ])
        return
      }
      let id = "parallex-release-" + UUID().uuidString
      releases[id] = message
      hiddenRequests.insert(id)
      send(["id": id, "method": "thread/unsubscribe", "params": ["threadId": threadID]])
    } else if message["target"] == sourceID {
      finishHandoff(requestID, released: message["action"] == "closed")
    }
  }

  private func finishHandoff(_ id: String, released: Bool) {
    guard let handoff = handoffs.removeValue(forKey: id) else { return }
    if released {
      receiveInput(handoff.request)
    } else if let request = object(handoff.request) {
      if let requestID = request["id"] { resumeAttempts.remove(String(describing: requestID)) }
      fail(
        request,
        message:
          "This task is still open in another billing account instance. Finish its active work and try again. Its saved history remains available locally."
      )
    }
  }

  /// When native events arrive, this function tracks actual writer state without copying task contents.
  private func observeThread(_ message: [String: Any]) {
    let params = message["params"] as? [String: Any] ?? [:]
    let hasStartingRequest =
      message["id"].map { startingRequests[String(describing: $0)] != nil } ?? false
    let thread =
      params["thread"] as? [String: Any]
      ?? (hasStartingRequest
        ? (message["result"] as? [String: Any])?["thread"] as? [String: Any] : nil)
    if let id = thread?["id"] as? String, let status = thread?["status"] as? [String: Any],
      let type = status["type"] as? String, type != "notLoaded"
    {
      loadedThreads.insert(id)
      if type == "idle", !pendingTurns.values.contains(id) {
        idleThreads.insert(id)
      } else {
        idleThreads.remove(id)
      }
    }
    guard let threadID = params["threadId"] as? String else { return }
    if message["method"] as? String == "thread/status/changed" {
      let type = (params["status"] as? [String: Any])?["type"] as? String
      if type == "idle", !pendingTurns.values.contains(threadID) {
        idleThreads.insert(threadID)
      } else {
        idleThreads.remove(threadID)
      }
      if type != "notLoaded" { loadedThreads.insert(threadID) }
    }
    if message["method"] as? String == "thread/closed" {
      idleThreads.remove(threadID)
      loadedThreads.remove(threadID)
      for (id, release) in releases where release["thread"] == threadID {
        releases.removeValue(forKey: id)
        releasedThreads.insert(threadID)
        postOwnership([
          "action": "closed", "request": release["request"] ?? "",
          "thread": threadID, "target": release["source"] ?? "",
        ])
      }
      for input in releasePendingInput.removeValue(forKey: threadID) ?? [] { receiveInput(input) }
    }
  }

  private func postOwnership(_ message: [String: String]) {
    var message = message
    message["source"] = sourceID
    DistributedNotificationCenter.default().postNotificationName(
      ownershipNotification,
      object: sharedHome, userInfo: message, deliverImmediately: true)
  }

  private func installCredential() -> String? {
    guard let credential = credential() else { return nil }
    let id = "parallex-install-auth-" + UUID().uuidString
    hiddenRequests.insert(id)
    send(["id": id, "method": "account/login/start", "params": credential])
    return id
  }

  private func clearCredential() {
    let id = "parallex-clear-auth-" + UUID().uuidString
    hiddenRequests.insert(id)
    send(["id": id, "method": "account/logout", "params": NSNull()])
  }

  /// When auth is needed, this function reads a private regular file without following credential links.
  private func credential() -> [String: Any]? {
    let path = URL(fileURLWithPath: authHome).appendingPathComponent("auth.json").path
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
      info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
      info.st_size <= 10 * 1024 * 1024,
      let data = try? handle.readToEnd(), let auth = object(data),
      let tokens = auth["tokens"] as? [String: Any],
      let accessToken = tokens["access_token"] as? String,
      let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
      !accessToken.isEmpty
    else { return nil }
    return [
      "type": "chatgptAuthTokens", "accessToken": accessToken,
      "chatgptAccountId": accountID,
    ]
  }

  private func fail(_ request: [String: Any], message: String) {
    guard var id = request["id"] else { return }
    if let key = id as? String, let pending = recoveringTurns.removeValue(forKey: key) {
      hiddenRequests.remove(key)
      startingRequests.removeValue(forKey: key)
      resumeRequests.removeValue(forKey: key)
      if let originalID = object(pending)?["id"] { id = originalID }
    }
    let response: [String: Any] = [
      "id": id,
      "error": ["code": -32000, "message": message],
    ]
    if request["method"] as? String == "account/chatgptAuthTokens/refresh" {
      send(response)
    } else {
      emit(encoded(response))
    }
  }

  private func object(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func encoded(_ message: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
    data.append(0x0A)
    return data
  }

  private func send(_ message: [String: Any]) { write(encoded(message)) }
  private func failHelper() {
    helperUnavailable = true
    helperReady = false
    pendingHelper.removeAll()
    let requests = helperRequests.values
    helperRequests.removeAll()
    for request in requests {
      fail(request, message: "The account credential process stopped. Reopen this instance.")
    }
  }

  private func sendHelper(_ message: [String: Any]) {
    guard !helperUnavailable else { return }
    do { try helperInput.fileHandleForWriting.write(contentsOf: encoded(message)) } catch {
      failHelper()
    }
  }
}
