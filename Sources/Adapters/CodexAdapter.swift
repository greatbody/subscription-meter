import Foundation

struct CodexAdapter: UsageAdapter {
    let provider: ProviderID = .codex
    func fetch() async throws -> ProviderUsage {
        try await Task.detached {
            let input = "{\"id\":0,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"subscription_meter\",\"title\":\"Subscription Meter\",\"version\":\"1.0\"}}}\n"
            let followup = "{\"method\":\"initialized\",\"params\":{}}\n{\"id\":6,\"method\":\"account/rateLimits/read\"}\n"
            let data = try CommandRunner.run("codex", arguments: ["app-server"], input: input, afterInitialize: followup, responseID: 6)
            return try Self.parse(data)
        }.value
    }
    static func parse(_ data: Data) throws -> ProviderUsage {
        guard let text = String(data: data, encoding: .utf8) else { throw AdapterError.message("Codex 返回了无效数据") }
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any], object["id"] as? Int == 6 else { continue }
            if object["error"] != nil { throw AdapterError.message("Codex 无法读取用量，请检查 ChatGPT 登录状态") }
            guard let result = object["result"] as? [String: Any], let limits = result["rateLimits"] as? [String: Any] else { break }
            var windows: [UsageWindow] = []
            for key in ["primary", "secondary"] {
                guard let value = limits[key] as? [String: Any], let used = value["usedPercent"] as? Double else { continue }
                let mins = value["windowDurationMins"] as? Int
                let title: String
                switch mins {
                case 300: title = "5 小时窗口"
                case 10080: title = "每周窗口"
                case let n? where n % 1440 == 0: title = "\(n / 1440) 天窗口"
                case let n? where n % 60 == 0: title = "\(n / 60) 小时窗口"
                case let n?: title = "\(n) 分钟窗口"
                default: title = key == "primary" ? "主要窗口" : "次要窗口"
                }
                let reset = (value["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:))
                windows.append(UsageWindow(id: key, title: title, usedPercent: max(0, min(100, used)), resetsAt: reset, detail: nil, cycle: mins == 10080 ? .week : nil))
            }
            guard !windows.isEmpty else { throw AdapterError.message("Codex 未返回用量窗口，请检查账户类型") }
            return ProviderUsage(provider: .codex, windows: windows, updatedAt: Date(), error: nil)
        }
        throw AdapterError.message("Codex 未返回用量，请检查登录状态")
    }
}
