import Foundation
import Security

// Claude Code keeps its subscription OAuth credential in Keychain on macOS.
// The credential is read on demand and is never written, printed, or transmitted elsewhere.
struct ClaudeAdapter: UsageAdapter {
    let provider: ProviderID = .claude
    func fetch() async throws -> ProviderUsage {
        let token = try Self.readClaudeToken()
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { throw AdapterError.message("无效的服务地址") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AdapterError.message("Claude 未返回有效响应") }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 { throw AdapterError.message("Claude 登录已过期或无用量权限，请重新登录 Claude Code") }
            if response.statusCode == 429 { throw AdapterError.message("Claude 请求过于频繁，请稍后重试") }
            throw AdapterError.message("Claude 用量请求失败（HTTP \(response.statusCode)）")
        }
        return try Self.parse(data)
    }
    static func readClaudeToken() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Claude Code-credentials",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let data: Data
        if status == errSecSuccess, let value = item as? Data { data = value }
        else {
            let path = NSHomeDirectory() + "/.claude/.credentials.json"
            guard let value = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw AdapterError.message("未找到 Claude Code 登录，请先运行 claude 登录") }
            data = value
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw AdapterError.message("Claude Code 凭据不可用，请重新登录")
        }
        return token
    }
    static func parse(_ data: Data) throws -> ProviderUsage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AdapterError.message("Claude 返回了无效数据") }
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let known = [("five_hour", "5 小时窗口"), ("seven_day", "每周窗口"), ("seven_day_sonnet", "Sonnet 每周窗口")]
        let windows: [UsageWindow] = known.compactMap { key, title in
            guard let value = object[key] as? [String: Any], let usage = value["utilization"] as? Double else { return nil }
            let reset = (value["resets_at"] as? String).flatMap { fractional.date(from: $0) ?? formatter.date(from: $0) }
            return UsageWindow(id: key, title: title, usedPercent: max(0, min(100, usage)), resetsAt: reset, detail: nil, cycle: key.hasPrefix("seven_day") ? .week : nil)
        }
        guard !windows.isEmpty else { throw AdapterError.message("Claude 未返回用量窗口") }
        return ProviderUsage(provider: .claude, windows: windows, updatedAt: Date(), error: nil)
    }
}
