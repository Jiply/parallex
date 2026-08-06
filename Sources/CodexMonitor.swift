import Combine
import Foundation

enum BillingConfidence: String, Hashable {
  case observed
  case current
  case changed
}

struct BillingAccount: Identifiable, Hashable {
  let id: String
  let email: String?
  let planType: String?
  let kind: String

  var displayName: String {
    if let email, !email.isEmpty {
      return email
    }

    if kind == "apiKey" {
      return "OpenAI API key"
    }

    if kind == "amazonBedrock" {
      return "Amazon Bedrock"
    }

    return "Account unavailable"
  }

  var planName: String? {
    guard let planType, !planType.isEmpty else { return nil }

    switch planType {
    case "self_serve_business_usage_based", "business":
      return "Business"
    case "enterprise_cbp_usage_based", "enterprise":
      return "Enterprise"
    case "prolite":
      return "Pro Lite"
    default:
      return planType.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}

struct CodexSession: Identifiable, Hashable {
  let id: String
  let title: String
  let workspace: String
  let originator: String
  let accountID: String
  let processID: Int32
  let startedAt: Date?
  let billingConfidence: BillingConfidence
  let subagentCount: Int
}

struct CodexSnapshot {
  let sessions: [CodexSession]
  let accounts: [BillingAccount]
  let scannedAt: Date

  static let empty = CodexSnapshot(sessions: [], accounts: [], scannedAt: Date())
}

final class CodexMonitor: ObservableObject {
  @Published private(set) var snapshot = CodexSnapshot.empty
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastError: String?

  private let scanner = CodexScanner()
  private var refreshInFlight = false
  private var timer: Timer?

  /// When the app starts observing, this function refreshes immediately and installs the polling timer.
  func start() {
    refresh()

    let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      self?.refresh()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// When the app terminates, this function stops background observation.
  func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// When UI or polling requests fresh data, this function scans away from the main thread.
  func refresh() {
    guard !refreshInFlight else { return }

    refreshInFlight = true
    isRefreshing = true

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }

      let result = Result {
        try self.scanner.scan()
      }

      DispatchQueue.main.async {
        self.refreshInFlight = false
        self.isRefreshing = false

        switch result {
        case .success(let snapshot):
          self.snapshot = snapshot
          self.lastError = nil
        case .failure(let error):
          self.lastError = error.localizedDescription
        }
      }
    }
  }
}
