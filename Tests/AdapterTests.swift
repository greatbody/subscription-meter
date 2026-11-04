import Foundation
import Darwin

@main struct AdapterTests {
    static var failures = 0
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        if condition() { print("PASS: \(description)") }
        else { failures += 1; print("FAIL: \(description)") }
    }
    static func bytes(_ string: String) -> Data { Data(string.utf8) }
    static func main() throws {
        check(UsageLevel.forPercent(69.9) == .healthy && UsageLevel.forPercent(70) == .warning && UsageLevel.forPercent(89.9) == .warning && UsageLevel.forPercent(90) == .critical, "color thresholds match displayed percentage")
        let copilot = try CopilotAdapter.parse(bytes(#"{"quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":{"percent_remaining":93.9,"credits_used":9999,"quota_remaining":18780,"remaining":17000,"quota_reset_at":1796041800,"entitlement":20000,"token_based_billing":true,"unlimited":false}}}"#))
        check(copilot.windows.count == 1 && abs(copilot.windows[0].usedPercent - 6.1) < 0.0001, "Copilot remaining to used conversion")
        check(copilot.windows[0].detail?.replacingOccurrences(of: ",", with: "") == "1220 / 20000 credits" && copilot.windows[0].resetsAt?.timeIntervalSince1970 == 1796041800, "Copilot detail uses entitlement basis and precise reset")
        let fallback = try CopilotAdapter.parse(bytes(#"{"token_based_billing":true,"quota_reset_date_utc":"2026-12-01T12:30:00Z","quota_snapshots":{"premium_interactions":{"percent_remaining":75,"credits_used":9999,"entitlement":100}}}"#))
        check(fallback.windows[0].detail == "25 / 100 credits" && fallback.windows[0].resetsAt != nil, "Copilot percentage fallback and UTC reset")
        let zeroReset = try CopilotAdapter.parse(bytes(#"{"quota_reset_date_utc":"2026-12-01T12:30:00Z","quota_snapshots":{"premium_interactions":{"percent_remaining":75,"quota_reset_at":0,"entitlement":100}}}"#))
        check(zeroReset.windows[0].resetsAt == fallback.windows[0].resetsAt, "Copilot zero reset falls back to account reset")
        do { _ = try CopilotAdapter.parse(bytes("{}")); check(false, "Copilot malformed response fails") }
        catch { check(true, "Copilot malformed response fails") }
        let codexResponse = """
        {"id":0,"result":{}}
        {"id":6,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1790000000},"secondary":{"usedPercent":68,"windowDurationMins":10080,"resetsAt":1791000000}}}}
        """
        let codex = try CodexAdapter.parse(bytes(codexResponse))
        check(codex.windows.map(\.title) == ["5 小时窗口", "每周窗口"], "Codex window duration labels")
        check(codex.windows.map(\.cycle) == [nil, .week], "Only weekly Codex window has a cycle")
        check(codex.windows.map(\.usedPercent) == [42, 68] && codex.windows.allSatisfy { $0.resetsAt != nil }, "Codex values and reset dates")
        do { _ = try CodexAdapter.parse(bytes(#"{"id":6,"error":{"message":"no"}}"#)); check(false, "Codex protocol error fails") }
        catch { check(true, "Codex protocol error fails") }
        let claude = try ClaudeAdapter.parse(bytes(#"{"five_hour":{"utilization":23.5,"resets_at":"2026-12-01T10:00:00.123Z"},"seven_day":{"utilization":72,"resets_at":"2026-12-07T10:00:00Z"},"seven_day_sonnet":null}"#))
        check(claude.windows.map(\.usedPercent) == [23.5,72] && claude.windows.allSatisfy { $0.resetsAt != nil }, "Claude optional windows and both date formats")
        check(claude.windows.map(\.cycle) == [nil, .week], "Only weekly Claude window has a cycle")
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        let week = UsageWindow(id: "week", title: "周", usedPercent: 6, resetsAt: end, detail: nil, cycle: .week)
        check(abs((week.elapsedFraction(at: end.addingTimeInterval(-3.5 * 86400)) ?? -1) - 0.5) < 0.00001, "Weekly cycle midpoint")
        check(week.elapsedFraction(at: end) == nil && week.elapsedFraction(at: end.addingTimeInterval(-8 * 86400)) == nil, "Stale and future cycles are not displayed")
        let dates = ISO8601DateFormatter()
        let monthly = UsageWindow(id: "month", title: "月", usedPercent: 6, resetsAt: dates.date(from: "2024-03-01T00:00:00Z"), detail: nil, cycle: .month)
        let febMidpoint = dates.date(from: "2024-02-15T12:00:00Z")!
        check(abs((monthly.elapsedFraction(at: febMidpoint) ?? -1) - 0.5) < 0.00001, "Monthly cycle uses actual leap-month length")
        check(codex.windows[0].elapsedFraction(at: end) == nil, "Short or unspecified windows have no time progress")
        do { _ = try ClaudeAdapter.parse(bytes("{}")); check(false, "Claude missing windows fails") }
        catch { check(true, "Claude missing windows fails") }

        let deepseek = try DeepSeekAdapter.parse(bytes(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"10.25","granted_balance":"0.20","topped_up_balance":"10.05"},{"currency":"USD","total_balance":"0.0001","granted_balance":"0","topped_up_balance":"0.0001"}]}"#))
        check(deepseek.isConnected && deepseek.balance?.isAvailable == true && deepseek.balance?.amounts.count == 2 && deepseek.balance?.amounts.first?.total == Decimal(string: "10.25"), "DeepSeek multiple currencies and exact decimal")
        let unavailable = try DeepSeekAdapter.parse(bytes(#"{"is_available":false,"balance_infos":[]}"#))
        check(unavailable.isConnected && unavailable.balance?.isAvailable == false && unavailable.balance?.amounts.isEmpty == true, "DeepSeek zero balance is a connected response")
        do { _ = try DeepSeekAdapter.parse(bytes(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12bad","granted_balance":"0","topped_up_balance":"12"}]}"#)); check(false, "DeepSeek rejects malformed decimal") }
        catch { check(true, "DeepSeek rejects malformed decimal") }
        do { _ = try DeepSeekAdapter.parse(bytes(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1","granted_balance":"0","topped_up_balance":"1"},{"currency":"USD","total_balance":"1","granted_balance":"0","topped_up_balance":"1"}]}"#)); check(false, "DeepSeek rejects duplicate currencies") }
        catch { check(true, "DeepSeek rejects duplicate currencies") }
        check(SiliconFlowStage.fromPage("walletReceived") == .walletReceived && SiliconFlowStage.fromPage("layoutMismatch") == .layoutMismatch && SiliconFlowStage.fromPage("verified") == nil && SiliconFlowStage.fromPage("loginRequired") == nil && SiliconFlowStage.fromPage("unexpected-account-data") == nil, "SiliconFlow accepts only trusted diagnostic stages")
        check(SiliconFlowSession.needsReload(isVisible: false, isLoading: false, elapsed: 601) && !SiliconFlowSession.needsReload(isVisible: true, isLoading: false, elapsed: 601) && !SiliconFlowSession.needsReload(isVisible: false, isLoading: true, elapsed: 601) && !SiliconFlowSession.needsReload(isVisible: false, isLoading: false, elapsed: 30), "SiliconFlow refreshes even after cache expiry without interrupting visible login")
        check(SiliconFlowSession.parseCash("12.34") == Decimal(string: "12.34") && SiliconFlowSession.parseCash("0") == 0, "SiliconFlow strict CNY parsing")
        check(SiliconFlowSession.parseCash("-1") == nil && SiliconFlowSession.parseCash("1,000") == nil && SiliconFlowSession.parseCash("1abc") == nil && SiliconFlowSession.parseCash("1.1234567890123") == nil, "SiliconFlow rejects ambiguous amounts")
        let fakeKey = try DeepSeekAdapter.readKey("OTHER_KEY=ignore\nexport DEEPSEEK_API_KEY='example-key'\n")
        check(fakeKey == "example-key", "DeepSeek reads only the named dotenv key")
        do { _ = try DeepSeekAdapter.readKey("DEEPSEEK_API_KEY=bad value\n"); check(false, "DeepSeek rejects malformed credentials") }
        catch { check(true, "DeepSeek rejects malformed credentials") }
        do { _ = try DeepSeekAdapter.readKey("OTHER_KEY=example\n"); check(false, "DeepSeek reports missing credentials") }
        catch { check(true, "DeepSeek reports missing credentials") }

        let output = try CommandRunner.run("sh", arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x"], timeout: 5)
        check(output.count == 200000, "command stdout fully drained")
        let start = Date()
        do {
            _ = try CommandRunner.run("sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.3)
            check(false, "non-cooperative command times out")
        } catch { check(Date().timeIntervalSince(start) < 3, "non-cooperative command times out") }

        // The fake server sends its initialize response only after reading request 0,
        // then checks that the initialized notification precedes the rate-limit request.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fake = temp.appendingPathComponent("meter-fake-server")
        let script = """
        #!/bin/sh
        IFS= read -r first || exit 1
        case "$first" in *'"method":"initialize"'*) ;; *) exit 2;; esac
        printf '%s\\n' '{"id":0,"result":{}}'
        IFS= read -r second || exit 3
        case "$second" in *'"method":"initialized"'*) ;; *) exit 4;; esac
        IFS= read -r third || exit 5
        case "$third" in *'"method":"account/rateLimits/read"'*) ;; *) exit 6;; esac
        printf '%s\\n' '{"id":6,"result":{"rateLimits":{"primary":{"usedPercent":11,"windowDurationMins":300}}}}'
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", temp.path + ":" + originalPath, 1)
        let initialize = "{\"id\":0,\"method\":\"initialize\"}\n"
        let followup = "{\"method\":\"initialized\"}\n{\"id\":6,\"method\":\"account/rateLimits/read\"}\n"
        let response = try CommandRunner.run("meter-fake-server", arguments: [], input: initialize, afterInitialize: followup, responseID: 6, timeout: 3)
        let protocolResult = try CodexAdapter.parse(response)
        check(protocolResult.windows.first?.usedPercent == 11, "Codex initialize handshake and matching response")
        if failures > 0 { exit(1) }
        print("All adapter tests passed.")
    }
}
