import Darwin
import Foundation

private struct SessionCandidate: Hashable {
  let processID: Int32
  let path: String
}

private struct ProcessContext {
  let processID: Int32
  let executablePath: String?
  let codexHome: String
  let sqliteHome: String?
  let usesManagedFileCredentials: Bool
}

private struct SessionMetadata {
  let id: String
  let workspace: String
  let originator: String
  let parentThreadID: String?
  let isSubagent: Bool
}

private struct LifecycleSignal {
  let isActive: Bool
  let timestamp: Date?
}

private struct CachedAccount {
  let account: BillingAccount
  let fetchedAt: Date
}

private enum CodexScannerError: LocalizedError {
  case lsofUnavailable
  case lsofFailed

  var errorDescription: String? {
    switch self {
    case .lsofUnavailable:
      return "Parallex could not find the macOS process inspector."
    case .lsofFailed:
      return "Parallex could not inspect local Codex sessions."
    }
  }
}

final class CodexScanner {
  private let fileManager = FileManager.default
  private let accountCacheLifetime: TimeInterval = 15
  private let accountCacheLock = NSLock()
  private var accountCache: [String: CachedAccount] = [:]

  /// When Parallex refreshes, this function joins live Codex processes, rollout lifecycles, and billing accounts.
  func scan() throws -> CodexSnapshot {
    let profiles = CodexProfileManager().profiles()
    let managedHomes = Set(profiles.map { $0.homeURL.standardizedFileURL.path })
    let candidates = try openSessionCandidates()
    var metadataByPath: [String: SessionMetadata] = [:]
    for candidate in candidates where metadataByPath[candidate.path] == nil {
      metadataByPath[candidate.path] = sessionMetadata(at: candidate.path)
    }
    var metadataByID: [String: SessionMetadata] = [:]
    for metadata in metadataByPath.values {
      metadataByID[metadata.id] = metadata
    }
    let activeCandidates = candidates.compactMap { candidate -> (SessionCandidate, LifecycleSignal)? in
      guard let signal = latestLifecycleSignal(at: candidate.path), signal.isActive else { return nil }
      guard processIsRunning(candidate.processID) else { return nil }
      return (candidate, signal)
    }
    let contexts = Dictionary(
      uniqueKeysWithValues: Set(activeCandidates.map(\.0.processID)).map { processID in
        (processID, processContext(for: processID, managedHomes: managedHomes))
      }
    )

    var contextByHome: [String: ProcessContext] = [:]
    for context in contexts.values {
      contextByHome[context.codexHome] = context
    }

    for profile in profiles {
      let profileHome = profile.homeURL.standardizedFileURL.path
      if contextByHome[profileHome] == nil {
        contextByHome[profileHome] = ProcessContext(
          processID: 0,
          executablePath: defaultCodexExecutable(),
          codexHome: profileHome,
          sqliteHome: defaultCodexHome(),
          usesManagedFileCredentials: true
        )
      }
    }

    if contextByHome.isEmpty {
      let defaultHome = defaultCodexHome()
      contextByHome[defaultHome] = ProcessContext(
        processID: 0,
        executablePath: defaultCodexExecutable(),
        codexHome: defaultHome,
        sqliteHome: nil,
        usesManagedFileCredentials: false
      )
    }

    let accountContexts = Array(contextByHome.values)
    let accountsLock = NSLock()
    var accounts: [BillingAccount] = []
    let nextIndexLock = NSLock()
    var nextIndex = 0
    let workerCount = min(3, accountContexts.count)
    DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
      while true {
        nextIndexLock.lock()
        guard nextIndex < accountContexts.count else {
          nextIndexLock.unlock()
          return
        }
        let index = nextIndex
        nextIndex += 1
        nextIndexLock.unlock()

        let observedAccount = account(for: accountContexts[index])
        accountsLock.lock()
        accounts.append(observedAccount)
        accountsLock.unlock()
      }
    }
    accounts.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    let accountIDsByHome = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.id) })
    let titlesByHome = Dictionary(
      uniqueKeysWithValues: contextByHome.keys.map { home in
        (home, threadTitles(in: home))
      }
    )

    var seenThreadIDs = Set<String>()
    var sessions: [CodexSession] = []
    var activeSubagentIDsBySessionID: [String: Set<String>] = [:]

    for (candidate, _) in activeCandidates {
      guard
        let metadata = metadataByPath[candidate.path],
        metadata.isSubagent,
        let parentSessionID = topLevelThreadID(for: metadata, metadataByID: metadataByID)
      else {
        continue
      }
      activeSubagentIDsBySessionID[parentSessionID, default: []].insert(metadata.id)
    }

    for (candidate, signal) in activeCandidates {
      guard let context = contexts[candidate.processID] else { continue }
      let observedMetadata = metadataByPath[candidate.path]
      let observedSessionID = observedMetadata?.id ?? threadID(from: candidate.path)
      let sessionID: String
      if let observedMetadata, observedMetadata.isSubagent {
        guard
          let parentSessionID = topLevelThreadID(
            for: observedMetadata,
            metadataByID: metadataByID
          )
        else {
          continue
        }
        sessionID = parentSessionID
      } else {
        sessionID = observedSessionID
      }
      guard !sessionID.isEmpty, seenThreadIDs.insert(sessionID).inserted else { continue }

      let metadata = metadataByID[sessionID] ?? observedMetadata
      let workspace = metadata?.workspace ?? "Unknown workspace"
      let title = titlesByHome[context.codexHome]?[sessionID]
        ?? fallbackTitle(workspace: workspace, originator: metadata?.originator)
      let accountID = accountIDsByHome[context.codexHome] ?? context.codexHome

      sessions.append(
        CodexSession(
          id: sessionID,
          title: title,
          workspace: workspace,
          originator: metadata?.originator ?? "Codex",
          accountID: accountID,
          processID: candidate.processID,
          startedAt: signal.timestamp,
          billingConfidence: billingConfidence(
            codexHome: context.codexHome,
            turnStartedAt: signal.timestamp
          ),
          subagentCount: activeSubagentIDsBySessionID[sessionID]?.count ?? 0
        )
      )
    }

    sessions.sort {
      let leftDate = $0.startedAt ?? .distantPast
      let rightDate = $1.startedAt ?? .distantPast
      return leftDate > rightDate
    }

    return CodexSnapshot(sessions: sessions, accounts: accounts, scannedAt: Date())
  }

  /// When live Codex runtimes are present, this function returns only their open rollout files.
  private func openSessionCandidates() throws -> [SessionCandidate] {
    let executable = "/usr/sbin/lsof"
    guard fileManager.isExecutableFile(atPath: executable) else {
      throw CodexScannerError.lsofUnavailable
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-nP", "-Fpcn", "-c", "codex"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
      throw CodexScannerError.lsofFailed
    }

    var currentProcessID: Int32?
    var candidates = Set<SessionCandidate>()
    let text = String(decoding: data, as: UTF8.self)

    for line in text.split(separator: "\n") {
      guard let marker = line.first else { continue }

      if marker == "p" {
        currentProcessID = Int32(line.dropFirst())
        continue
      }

      guard marker == "n", let processID = currentProcessID else { continue }
      let path = String(line.dropFirst())
      guard
        path.contains("/sessions/"),
        path.hasSuffix(".jsonl"),
        URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-")
      else {
        continue
      }

      candidates.insert(SessionCandidate(processID: processID, path: path))
    }

    return Array(candidates)
  }

  /// When a rollout is open, this function finds its newest lifecycle marker without reading transcript content.
  private func latestLifecycleSignal(at path: String) -> LifecycleSignal? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer {
      try? handle.close()
    }

    let patterns: [(data: Data, isActive: Bool)] = [
      (Data(#""type":"task_started""#.utf8), true),
      (Data(#""type":"task_complete""#.utf8), false),
      (Data(#""type":"turn_aborted""#.utf8), false),
    ]
    let chunkSize: UInt64 = 256 * 1024
    let overlap: UInt64 = 64

    guard let fileSize = try? handle.seekToEnd() else { return nil }
    var endOffset = fileSize

    while endOffset > 0 {
      let startOffset = endOffset > chunkSize ? endOffset - chunkSize : 0
      guard
        (try? handle.seek(toOffset: startOffset)) != nil,
        let data = try? handle.read(upToCount: Int(endOffset - startOffset))
      else {
        return nil
      }

      let matches = patterns.compactMap { pattern -> (range: Range<Data.Index>, isActive: Bool)? in
        guard let range = data.range(of: pattern.data, options: .backwards) else { return nil }
        return (range, pattern.isActive)
      }

      if let match = matches.max(by: { $0.range.lowerBound < $1.range.lowerBound }) {
        return LifecycleSignal(
          isActive: match.isActive,
          timestamp: timestamp(in: data, around: match.range)
        )
      }

      guard startOffset > 0 else { break }
      endOffset = startOffset + overlap
    }

    return nil
  }

  /// When a lifecycle marker is found, this function decodes only that line's timestamp.
  private func timestamp(in data: Data, around range: Range<Data.Index>) -> Date? {
    let prefix = data[..<range.lowerBound]
    let suffix = data[range.upperBound...]
    let lineStart = prefix.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
    let lineEnd = suffix.firstIndex(of: 0x0A) ?? data.endIndex
    let line = Data(data[lineStart..<lineEnd])

    guard
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let timestamp = object["timestamp"] as? String
    else {
      return nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: timestamp)
  }

  /// When a session row needs context, this function reads only the first session metadata record.
  private func sessionMetadata(at path: String) -> SessionMetadata? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer {
      try? handle.close()
    }

    guard let data = try? handle.read(upToCount: 4 * 1024 * 1024) else { return nil }
    let lineEnd = data.firstIndex(of: 0x0A) ?? data.endIndex
    let line = Data(data[..<lineEnd])

    guard
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["type"] as? String == "session_meta",
      let payload = object["payload"] as? [String: Any]
    else {
      return nil
    }

    let id = payload["id"] as? String ?? threadID(from: path)
    let cwd = payload["cwd"] as? String
    let workspace = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown workspace"
    let originator = payload["originator"] as? String
      ?? payload["source"] as? String
      ?? "Codex"
    let source = payload["source"] as? [String: Any]
    let subagent = source?["subagent"] as? [String: Any]
    let threadSpawn = subagent?["thread_spawn"] as? [String: Any]
    let parentThreadID = threadSpawn?["parent_thread_id"] as? String

    return SessionMetadata(
      id: id,
      workspace: workspace,
      originator: originator,
      parentThreadID: parentThreadID,
      isSubagent: subagent != nil
    )
  }

  /// When a spawned subagent is active, this function resolves it to one top-level session row.
  private func topLevelThreadID(
    for metadata: SessionMetadata,
    metadataByID: [String: SessionMetadata]
  ) -> String? {
    guard metadata.isSubagent, var threadID = metadata.parentThreadID else { return nil }
    var visitedThreadIDs = Set([metadata.id])

    while let parentMetadata = metadataByID[threadID] {
      guard visitedThreadIDs.insert(threadID).inserted else { return nil }
      guard parentMetadata.isSubagent else { return parentMetadata.id }
      guard let parentThreadID = parentMetadata.parentThreadID else { return nil }
      threadID = parentThreadID
    }

    return threadID
  }

  /// When Codex has named threads, this function reads the token-free local title index.
  private func threadTitles(in codexHome: String) -> [String: String] {
    let path = URL(fileURLWithPath: codexHome)
      .appendingPathComponent("session_index.jsonl")
      .path
    guard let data = fileManager.contents(atPath: path) else { return [:] }

    var titles: [String: String] = [:]
    for line in data.split(separator: 0x0A) {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let id = object["id"] as? String,
        let title = object["thread_name"] as? String,
        !title.isEmpty
      else {
        continue
      }
      titles[id] = title
    }
    return titles
  }

  /// When a runtime PID is known, this function extracts only its executable and Codex home fields.
  private func processContext(for processID: Int32, managedHomes: Set<String>) -> ProcessContext {
    let data = processArguments(for: processID)
    let executablePath = data.flatMap(executablePath(from:))
    let codexHome = data.flatMap { environmentValue(named: "CODEX_HOME", in: $0) }
      ?? defaultCodexHome()
    let sqliteHome = data.flatMap { environmentValue(named: "CODEX_SQLITE_HOME", in: $0) }

    let standardizedHome = URL(fileURLWithPath: codexHome).standardized.path
    return ProcessContext(
      processID: processID,
      executablePath: executablePath,
      codexHome: standardizedHome,
      sqliteHome: sqliteHome,
      usesManagedFileCredentials: managedHomes.contains(standardizedHome)
    )
  }

  /// When macOS permits same-user process inspection, this function reads the raw argument buffer transiently.
  private func processArguments(for processID: Int32) -> Data? {
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

  /// When a process buffer is available, this function returns its executable path without decoding arguments.
  private func executablePath(from data: Data) -> String? {
    let bytes = [UInt8](data)
    let start = MemoryLayout<Int32>.size
    guard start < bytes.count else { return nil }
    let end = bytes[start...].firstIndex(of: 0) ?? bytes.endIndex
    guard end > start else { return nil }
    return String(bytes: bytes[start..<end], encoding: .utf8)
  }

  /// When an isolated Codex profile is active, this function extracts one approved environment value byte-wise.
  private func environmentValue(named name: String, in data: Data) -> String? {
    let bytes = [UInt8](data)
    let needle = [UInt8]("\(name)=".utf8)
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

  /// When an account is needed, this function uses Codex's supported account API and a short-lived cache.
  private func account(for context: ProcessContext) -> BillingAccount {
    let cacheKey = "\(context.codexHome)|\(context.executablePath ?? "")|\(context.usesManagedFileCredentials)"
    accountCacheLock.lock()
    if
      let cached = accountCache[cacheKey],
      Date().timeIntervalSince(cached.fetchedAt) < accountCacheLifetime
    {
      accountCacheLock.unlock()
      return cached.account
    }
    accountCacheLock.unlock()

    let account = readAccount(from: context) ?? BillingAccount(
      id: context.codexHome,
      email: nil,
      planType: nil,
      kind: "unavailable"
    )
    accountCacheLock.lock()
    accountCache[cacheKey] = CachedAccount(account: account, fetchedAt: Date())
    accountCacheLock.unlock()
    return account
  }

  /// When a Codex runtime context is available, this function performs an initialized account/read handshake.
  private func readAccount(from context: ProcessContext) -> BillingAccount? {
    guard let executablePath = context.executablePath ?? defaultCodexExecutable() else { return nil }
    guard fileManager.isExecutableFile(atPath: executablePath) else { return nil }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executablePath)
    var arguments: [String] = []
    if context.usesManagedFileCredentials {
      arguments.append(contentsOf: [
        "-c",
        "cli_auth_credentials_store=file",
        "-c",
        "forced_login_method=chatgpt",
      ])
    }
    if let sqliteHome = context.sqliteHome {
      arguments.append(contentsOf: ["-c", "sqlite_home=\(sqliteHome)"])
    }
    arguments.append(contentsOf: [
      "app-server",
      "--stdio",
      "--disable",
      "plugins",
      "--disable",
      "remote_plugin",
      "--disable",
      "apps",
    ])
    process.arguments = arguments
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    let parentEnvironment = ProcessInfo.processInfo.environment
    var environment = [
      "HOME": fileManager.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "TMPDIR": NSTemporaryDirectory(),
    ]
    for key in ["LANG", "LC_ALL"] {
      if let value = parentEnvironment[key], !value.isEmpty {
        environment[key] = value
      }
    }
    environment["CODEX_HOME"] = context.codexHome
    if let sqliteHome = context.sqliteHome {
      environment["CODEX_SQLITE_HOME"] = sqliteHome
    }
    process.environment = environment

    let initializeSemaphore = DispatchSemaphore(value: 0)
    let accountSemaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var buffer = Data()
    var accountObject: [String: Any]?

    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }

      lock.lock()
      buffer.append(chunk)

      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)

        guard
          let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let id = message["id"] as? Int
        else {
          continue
        }

        if id == 1 {
          initializeSemaphore.signal()
        } else if id == 2 {
          accountObject = message["result"] as? [String: Any]
          accountSemaphore.signal()
        }
      }
      lock.unlock()
    }

    do {
      try process.run()
      try sendJSON(
        [
          "id": 1,
          "method": "initialize",
          "params": [
            "clientInfo": [
              "name": "parallex",
              "version": "0.1.0",
            ],
          ],
        ],
        to: input.fileHandleForWriting
      )

      guard initializeSemaphore.wait(timeout: .now() + 3) == .success else {
        cleanup(process: process, input: input, output: output)
        return nil
      }

      try sendJSON(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
      try sendJSON(
        [
          "id": 2,
          "method": "account/read",
          "params": ["refreshToken": false],
        ],
        to: input.fileHandleForWriting
      )

      guard accountSemaphore.wait(timeout: .now() + 3) == .success else {
        cleanup(process: process, input: input, output: output)
        return nil
      }
    } catch {
      cleanup(process: process, input: input, output: output)
      return nil
    }

    cleanup(process: process, input: input, output: output)

    lock.lock()
    let result = accountObject
    lock.unlock()

    guard let object = result else { return nil }
    guard let rawAccount = object["account"], !(rawAccount is NSNull) else {
      return BillingAccount(
        id: context.codexHome,
        email: nil,
        planType: nil,
        kind: "signedOut"
      )
    }
    guard let account = rawAccount as? [String: Any] else { return nil }

    return BillingAccount(
      id: context.codexHome,
      email: account["email"] as? String,
      planType: account["planType"] as? String,
      kind: account["type"] as? String ?? "unknown"
    )
  }

  /// When a JSON-RPC message is ready, this function writes one headerless JSONL record.
  private func sendJSON(_ object: [String: Any], to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }

  /// When an account probe finishes or times out, this function closes pipes and stops its helper process.
  private func cleanup(process: Process, input: Pipe, output: Pipe) {
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
    if process.isRunning {
      process.terminate()
    }
  }

  /// When a rollout was observed, this function confirms its owning process still exists.
  private func processIsRunning(_ processID: Int32) -> Bool {
    if kill(processID, 0) == 0 {
      return true
    }
    return errno == EPERM
  }

  /// When session identity is absent, this function derives the UUID suffix from the rollout filename.
  private func threadID(from path: String) -> String {
    let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard filename.count >= 36 else { return filename }
    return String(filename.suffix(36))
  }

  /// When a title is not indexed, this function creates a private fallback from non-transcript metadata.
  private func fallbackTitle(workspace: String, originator: String?) -> String {
    if let originator, !originator.isEmpty, originator != "Codex Desktop" {
      return "\(originator) · \(workspace)"
    }
    return "Codex · \(workspace)"
  }

  /// When an account file changed during a turn, this function keeps the UI honest about attribution.
  private func billingConfidence(codexHome: String, turnStartedAt: Date?) -> BillingConfidence {
    guard let turnStartedAt else { return .current }
    let path = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json").path
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: path),
      let modifiedAt = attributes[.modificationDate] as? Date
    else {
      return .current
    }
    return modifiedAt <= turnStartedAt ? .observed : .changed
  }

  /// When no profile override exists, this function returns the conventional per-user Codex home.
  private func defaultCodexHome() -> String {
    fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
  }

  /// When no live runtime exposes its executable, this function locates the bundled desktop Codex binary.
  private func defaultCodexExecutable() -> String? {
    let candidates = [
      "/Applications/ChatGPT.app/Contents/Resources/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
    ]
    return candidates.first(where: fileManager.isExecutableFile(atPath:))
  }
}
