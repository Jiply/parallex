import CryptoKit
import Foundation
import Network

/// When profiles have separate billing channels, this coordinator shares native read and archive events.
final class CodexReadStateBridge {
  private let queue = DispatchQueue(label: "org.curvelabs.Parallex.codex-read-state")
  private let codexHomeURL: URL
  private let profiles: () -> [CodexProfile]
  private var peers: [String: CodexReadStatePeer] = [:]
  private var identities: [[String: String]] = []
  private var states: [String: Bool] = [:]
  private var snapshots: [String: Set<String>] = [:]
  private var pending: [String: [String: Bool]] = [:]
  private var sources: [String: (url: URL, path: String, identity: [String: String])] = [:]
  private var stopped = true
  private let hostKey =
    "local:"
    + SHA256.hash(data: Data("[\"local\",\"local\",null]".utf8))
    .map { String(format: "%02x", $0) }.joined()

  init(
    codexHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".codex"),
    profiles: @escaping () -> [CodexProfile] = { CodexProfileManager().profiles() }
  ) {
    self.codexHomeURL = codexHomeURL
    self.profiles = profiles
  }

  func start() {
    queue.async {
      guard self.stopped else { return }
      self.stopped = false
      self.restore()
      self.refresh()
    }
  }

  func stop() {
    queue.async {
      self.stopped = true
      for peer in self.peers.values { peer.stop() }
      self.peers.removeAll()
    }
  }

  /// When saved profiles change, this function adds private sockets while retaining the legacy shared socket.
  private func refresh() {
    guard !stopped else { return }
    let profiles =
      profiles() + [
        CodexProfile(
          email: "", rootURL: codexHomeURL,
          homeURL: codexHomeURL, desktopDataURL: codexHomeURL)
      ]
    identities = profiles.compactMap(identity).reduce(into: []) { result, identity in
      if !result.contains(identity) { result.append(identity) }
    }
    sources.removeAll()
    for profile in profiles {
      guard let identity = identity(profile),
        let data = try? JSONSerialization.data(
          withJSONObject: [
            "chatgpt", identity["accountId"]!, identity["userId"]!,
          ], options: [.withoutEscapingSlashes])
      else { continue }
      let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      let path = profile.homeURL.appendingPathComponent("ipc/ipc.sock")
        .resolvingSymlinksInPath().path
      let pathHash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
      sources[pathHash + "\n" + hash] = (
        profile.homeURL.appendingPathComponent(".codex-global-state.json"), path, identity
      )
    }
    reconcile()
    let paths = Set(
      ([codexHomeURL] + profiles.map { $0.homeURL }).map {
        $0.appendingPathComponent("ipc/ipc.sock").resolvingSymlinksInPath().path
      })
    for path in Array(peers.keys) where !paths.contains(path) {
      peers.removeValue(forKey: path)?.stop()
    }
    for path in paths where peers[path] == nil {
      let peer = CodexReadStatePeer(
        socketURL: URL(fileURLWithPath: path), queue: queue,
        onReady: { [weak self] in self?.replay(to: path) },
        onMessage: { [weak self] message in self?.forward(message, from: path) }
      )
      peers[path] = peer
      peer.start()
    }
    queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
  }

  /// When a local task changes, this function shares display metadata without forwarding execution.
  private func forward(_ message: [String: Any], from path: String) {
    if message["type"] as? String == "broadcast",
      message["method"] as? String == "client-status-changed",
      let params = message["params"] as? [String: Any],
      params["status"] as? String == "connected", params["clientType"] as? String == "desktop"
    {
      replay(to: path)
      return
    }
    guard !stopped,
      message["type"] as? String == "broadcast",
      let sourceClientID = message["sourceClientId"] as? String,
      !peers.values.contains(where: { $0.clientID == sourceClientID }),
      let method = message["method"] as? String,
      let version = message["version"] as? Int,
      let params = message["params"] as? [String: Any],
      params["hostId"] as? String == "local",
      let threadID = params["conversationId"] as? String, !threadID.isEmpty
    else { return }
    if method == "thread-archived" && version == 2
      || method == "thread-unarchived" && version == 1
    {
      for (targetPath, peer) in peers where targetPath != path {
        guard let clientID = peer.clientID else { continue }
        peer.send([
          "type": "broadcast", "sourceClientId": clientID, "version": version,
          "method": method, "params": params,
        ])
      }
      return
    }
    guard method == "thread-read-state-changed", version == 3,
      let hasUnreadTurn = params["hasUnreadTurn"] as? Bool,
      let context = params["context"] as? [String: Any],
      context["executionHostKey"] as? String == hostKey,
      let sourceIdentity = context["identity"] as? [String: String],
      identities.contains(sourceIdentity)
    else { return }
    states[threadID] = hasUnreadTurn
    for key in sources.keys { pending[key, default: [:]][threadID] = hasUnreadTurn }
    persist()
    for (targetPath, peer) in peers {
      guard let clientID = peer.clientID else { continue }
      for identity in identities where targetPath != path || identity != sourceIdentity {
        peer.send([
          "type": "broadcast", "sourceClientId": clientID, "version": 3,
          "method": "thread-read-state-changed",
          "params": [
            "conversationId": threadID, "hostId": "local", "hasUnreadTurn": hasUnreadTurn,
            "context": ["identity": identity, "executionHostKey": hostKey],
          ],
        ])
      }
    }
  }

  /// When a peer reconnects, this function replays read tombstones as well as unread notifications.
  private func replay(to path: String) {
    for (threadID, unread) in states {
      for identity in identities { send(threadID, unread: unread, identity: identity, to: path) }
    }
    persist()
  }

  private func send(_ threadID: String, unread: Bool, identity: [String: String], to path: String) {
    guard let peer = peers[path], let clientID = peer.clientID else { return }
    for (key, source) in sources where source.path == path && source.identity == identity {
      pending[key, default: [:]][threadID] = unread
    }
    peer.send([
      "type": "broadcast", "sourceClientId": clientID, "version": 3,
      "method": "thread-read-state-changed",
      "params": [
        "conversationId": threadID, "hostId": "local", "hasUnreadTurn": unread,
        "context": ["identity": identity, "executionHostKey": hostKey],
      ],
    ])
  }

  /// When broadcasts are missed, this function reconciles each profile's own persisted unread list.
  private func reconcile() {
    var changes: [String: Bool] = [:]
    var current: [String: Set<String>] = [:]
    for (key, source) in sources {
      guard let data = try? Data(contentsOf: source.url), data.count <= 32 * 1024 * 1024,
        let global = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let hash = key.split(separator: "\n").last
      else { continue }
      let state = global["electron-thread-read-state-v1"] as? [String: Any]
      guard state == nil || state?["version"] as? Int == 1 else { continue }
      let buckets = state?["unreadByIdentity"] as? [String: [String: [String]]]
      let unread = Set(buckets?[String(hash)]?[hostKey] ?? [])
      current[key] = unread
      if let previous = snapshots[key] {
        for threadID in previous.symmetricDifference(unread) {
          let value = unread.contains(threadID)
          if pending[key]?[threadID] != value {
            // Without native revisions, a read wins simultaneous conflicting snapshot changes.
            changes[threadID] = (changes[threadID] ?? true) && value
          }
        }
      } else {
        // Preserve unread work on first adoption; absence alone is not evidence of a read.
        for threadID in unread where states[threadID] == nil { states[threadID] = true }
      }
      snapshots[key] = unread
      for (threadID, value) in pending[key] ?? [:] where unread.contains(threadID) == value {
        pending[key]?.removeValue(forKey: threadID)
      }
    }
    for (threadID, value) in changes { states[threadID] = value }
    for (key, unread) in current {
      guard let source = sources[key] else { continue }
      for (threadID, value) in states where unread.contains(threadID) != value {
        send(threadID, unread: value, identity: source.identity, to: source.path)
      }
    }
    persist()
  }

  private var journalURL: URL { codexHomeURL.appendingPathComponent("parallex-read-state.json") }

  private func restore() {
    guard let data = try? Data(contentsOf: journalURL), data.count <= 32 * 1024 * 1024,
      let journal = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      journal["version"] as? Int == 1,
      let states = journal["states"] as? [String: Bool],
      let snapshots = journal["snapshots"] as? [String: [String]],
      let pending = journal["pending"] as? [String: [String: Bool]]
    else { return }
    self.states = states
    self.snapshots = snapshots.mapValues { Set($0) }
    self.pending = pending
  }

  private func persist() {
    do {
      let data = try JSONSerialization.data(
        withJSONObject: [
          "version": 1, "states": states, "snapshots": snapshots.mapValues { $0.sorted() },
          "pending": pending,
        ], options: [.sortedKeys])
      if (try? Data(contentsOf: journalURL)) == data { return }
      let temporary = journalURL.deletingLastPathComponent()
        .appendingPathComponent(".parallex-read-state-" + UUID().uuidString)
      let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      guard descriptor >= 0 else { throw POSIXError(.EIO) }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer {
        try? file.close()
        try? FileManager.default.removeItem(at: temporary)
      }
      try file.write(contentsOf: data)
      try file.synchronize()
      guard rename(temporary.path, journalURL.path) == 0 else { throw POSIXError(.EIO) }
    } catch {
      NSLog("Parallex could not persist sidebar read-state reconciliation")
    }
  }

  /// When a profile has private credentials, this function reads only the account identity for IPC context.
  private func identity(_ profile: CodexProfile) -> [String: String]? {
    guard profile.hasCredentials,
      let data = try? Data(contentsOf: profile.authURL), data.count <= 10 * 1024 * 1024,
      let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String
    else { return nil }
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    guard let payload = Data(base64Encoded: encoded),
      let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let account = claims["https://api.openai.com/auth"] as? [String: Any],
      let accountID = (account["chatgpt_account_id"] ?? account["account_id"]) as? String,
      let userID = (account["user_id"] ?? account["chatgpt_user_id"]) as? String,
      !accountID.isEmpty, !userID.isEmpty
    else { return nil }
    return ["kind": "chatgpt", "accountId": accountID, "userId": userID]
  }

}

private final class CodexReadStatePeer {
  private let queue: DispatchQueue
  private let socketURL: URL
  private let onMessage: ([String: Any]) -> Void
  private let onReady: () -> Void
  private var connection: NWConnection?
  private(set) var clientID: String?
  private var buffer = Data()
  private var stopped = true

  init(
    socketURL: URL, queue: DispatchQueue, onReady: @escaping () -> Void,
    onMessage: @escaping ([String: Any]) -> Void
  ) {
    self.socketURL = socketURL
    self.queue = queue
    self.onMessage = onMessage
    self.onReady = onReady
  }

  /// When Parallex starts, this function connects away from the menu's main thread.
  func start() {
    queue.async {
      guard self.stopped else { return }
      self.stopped = false
      self.connect()
    }
  }

  /// When Parallex stops, this function closes its local notification connection.
  func stop() {
    queue.async {
      self.stopped = true
      self.connection?.cancel()
      self.connection = nil
      self.clientID = nil
    }
  }

  /// When Codex owns a private local socket, this function joins its notification channel.
  private func connect() {
    guard !stopped else { return }
    let paths = [socketURL.deletingLastPathComponent(), socketURL]
    guard
      paths.allSatisfy({ url in
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
          return false
        }
        return (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
          && ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0
          && attributes[.type] as? FileAttributeType
            == (url == socketURL ? .typeSocket : .typeDirectory)
      })
    else {
      queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connect() }
      return
    }
    buffer.removeAll()
    clientID = nil
    let connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
    self.connection = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection, self.connection === connection else { return }
      switch state {
      case .ready:
        self.send([
          "type": "request", "requestId": UUID().uuidString,
          "sourceClientId": "initializing-client", "version": 0, "method": "initialize",
          "params": ["clientType": "parallex"],
        ])
        self.receive(connection)
      case .failed, .waiting:
        self.reconnect(connection)
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  /// When Codex restarts, this function discards the old connection and retries without polling state files.
  private func reconnect(_ connection: NWConnection) {
    guard self.connection === connection else { return }
    self.connection = nil
    clientID = nil
    connection.cancel()
    queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connect() }
  }

  /// When IPC bytes arrive, this function decodes complete length-prefixed messages once.
  private func receive(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self, weak connection] data, _, complete, error in
      guard let self, let connection, self.connection === connection else { return }
      if let data { self.buffer.append(data) }
      while self.buffer.count >= 4 {
        let size = self.buffer.prefix(4).enumerated().reduce(0) {
          $0 | Int($1.element) << ($1.offset * 8)
        }
        guard size <= 16 * 1024 * 1024 else {
          self.reconnect(connection)
          return
        }
        guard self.buffer.count >= size + 4 else { break }
        let payload = Data(self.buffer.dropFirst(4).prefix(size))
        self.buffer.removeFirst(size + 4)
        if let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
          self.handle(message)
        }
      }
      if complete || error != nil {
        self.reconnect(connection)
      } else {
        self.receive(connection)
      }
    }
  }

  /// When a native event arrives, this function passes it to the shared coordinator.
  private func handle(_ message: [String: Any]) {
    if message["type"] as? String == "response", message["method"] as? String == "initialize" {
      clientID = (message["result"] as? [String: Any])?["clientId"] as? String
      if clientID != nil { onReady() }
      return
    }
    onMessage(message)
  }

  /// When a notification is ready, this function writes its framed JSON without blocking the UI.
  func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    var size = UInt32(data.count).littleEndian
    var frame = withUnsafeBytes(of: &size) { Data($0) }
    frame.append(data)
    connection?.send(content: frame, completion: .contentProcessed { _ in })
  }
}
