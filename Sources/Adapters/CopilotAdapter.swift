import Foundation

struct CopilotAdapter: UsageAdapter {
    let provider: ProviderID = .copilot
    func fetch() async throws -> ProviderUsage {
        try await Task.detached {
            let data = try CommandRunner.run("gh", arguments: ["api", "copilot_internal/user"])
            return try Self.parse(data)
        }.value
    }
    private static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? formatter.date(from: value + "T00:00:00Z")
    }
    static func parse(_ data: Data) throws -> ProviderUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = root["quota_snapshots"] as? [String: Any],
              let quota = snapshots["premium_interactions"] as? [String: Any],
              let remaining = quota["percent_remaining"] as? Double else {
            throw AdapterError.message("GitHub 未返回可用的 Copilot 额度")
        }
        if quota["unlimited"] as? Bool == true { throw AdapterError.message("此 Copilot 额度为无限量，无法计算百分比") }
        let tokenBased = (root["token_based_billing"] as? Bool) ?? (quota["token_based_billing"] as? Bool) ?? false
        let unit = tokenBased ? "credits" : "次请求"
        let entitlement = quota["entitlement"] as? Double
        // credits_used can describe an unmetered pool; only remaining shares the entitlement's basis.
        let used = entitlement.flatMap { total -> Double? in
            guard total > 0 else { return nil }
            return max(0, ((quota["quota_remaining"] as? Double) ?? (quota["remaining"] as? Double)).map { total - $0 } ?? total * (100 - remaining) / 100)
        }
        let detail: String? = if let entitlement, let used, entitlement > 0 {
            "\(Self.number(used)) / \(Self.number(entitlement)) \(unit)"
        } else { nil }
        let date: Date? = [quota["quota_reset_at"], quota["reset_at"]]
            .compactMap { $0 as? Double }.first(where: { $0.isFinite && $0 > 0 }).map(Date.init(timeIntervalSince1970:))
            ?? [root["quota_reset_date_utc"], root["quota_reset_date"]].compactMap { ($0 as? String).flatMap(Self.parseDate) }.first
        let window = UsageWindow(id: "monthly", title: tokenBased ? "月度 Credits" : "月度高级请求", usedPercent: max(0, min(100, 100 - remaining)), resetsAt: date, detail: detail, cycle: .month)
        return ProviderUsage(provider: .copilot, windows: [window], updatedAt: Date(), error: nil)
    }
}
