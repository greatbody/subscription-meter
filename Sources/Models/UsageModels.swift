import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case copilot, codex, claude, deepseek, siliconflow
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .copilot: return "GitHub Copilot"
        case .codex: return "ChatGPT"
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .siliconflow: return "硅基流动"
        }
    }
}

enum UsageLevel: Equatable {
    case healthy, warning, critical
    static func forPercent(_ value: Double) -> UsageLevel {
        let displayed = floor(value)
        if displayed >= 90 { return .critical }
        if displayed >= 70 { return .warning }
        return .healthy
    }
}

struct UsageWindow: Identifiable, Equatable {
    enum Cycle: Equatable { case week, month }
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    let detail: String?
    var cycle: Cycle? = nil

    func elapsedFraction(at now: Date = Date()) -> Double? {
        guard let cycle, let end = resetsAt, now < end else { return nil }
        let start: Date
        switch cycle {
        case .week: start = end.addingTimeInterval(-7 * 24 * 60 * 60)
        case .month:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let previous = calendar.date(byAdding: .month, value: -1, to: end) else { return nil }
            start = previous
        }
        guard now >= start, end > start else { return nil }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}

struct BalanceAmount: Identifiable, Equatable {
    let currency: String
    let total: Decimal
    let granted: Decimal?
    let toppedUp: Decimal?
    var id: String { currency }
}

struct AccountBalance: Equatable {
    let isAvailable: Bool?
    let amounts: [BalanceAmount]
}

struct ProviderUsage: Identifiable, Equatable {
    let provider: ProviderID
    let windows: [UsageWindow]
    let updatedAt: Date
    let error: String?
    let balance: AccountBalance?
    init(provider: ProviderID, windows: [UsageWindow], updatedAt: Date, error: String?, balance: AccountBalance? = nil) {
        self.provider = provider
        self.windows = windows
        self.updatedAt = updatedAt
        self.error = error
        self.balance = balance
    }
    var id: ProviderID { provider }
    var isConnected: Bool { error == nil && (!windows.isEmpty || balance != nil) }
}

protocol UsageAdapter {
    var provider: ProviderID { get }
    func fetch() async throws -> ProviderUsage
}

enum AdapterError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
