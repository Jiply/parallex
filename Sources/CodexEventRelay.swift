import Darwin
import Foundation

private let relayNotification = Notification.Name("org.curvelabs.Parallex.codex-thread-event")
private let relayableMethods = Set([
  "thread/name/updated",
  "thread/started",
  "thread/status/changed",
])

@main
enum CodexEventRelay {
  /// When Codex Desktop starts its app-server, this function proxies stdio and shares sidebar events.
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let executable = arguments.first else {
      FileHandle.standardError.write(Data("Missing Codex executable.\n".utf8))
      exit(64)
    }

    do {
      exit(try run(executable: executable, arguments: Array(arguments.dropFirst())))
    } catch {
      FileHandle.standardError.write(Data("Codex relay failed: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  /// When the child app-server runs, this function preserves its protocol while relaying thread events.
  private static func run(executable: String, arguments: [String]) throws -> Int32 {
    let process = Process()
    let childInput = Pipe()
    let childOutput = Pipe()
    let outputQueue = DispatchQueue(label: "org.curvelabs.Parallex.codex-relay-output")
    let sourceID = UUID().uuidString
    var parseBuffer = Data()

    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
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
        FileHandle.standardOutput.write(data)
      }
    }

    FileHandle.standardInput.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        try? childInput.fileHandleForWriting.close()
        return
      }
      childInput.fileHandleForWriting.write(data)
    }

    childOutput.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }

      outputQueue.async {
        FileHandle.standardOutput.write(data)
      }
      parseBuffer.append(data)

      while let newline = parseBuffer.firstIndex(of: 0x0A) {
        let line = Data(parseBuffer[...newline])
        parseBuffer.removeSubrange(...newline)
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
    }

    try process.run()
    while process.isRunning {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    FileHandle.standardInput.readabilityHandler = nil
    childOutput.fileHandleForReading.readabilityHandler = nil
    notificationCenter.removeObserver(observer)
    outputQueue.sync {}
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
