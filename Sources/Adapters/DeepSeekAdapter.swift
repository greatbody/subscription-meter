import Foundation

/// Reads only DEEPSEEK_API_KEY from ~/.env; never runs or sources the file.
/// The credential is held in memory only and sent solely to the official endpoint.
struct DeepSeekAdapter: UsageAdapter {
    let provider: ProviderID = .deepseek
    private static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    func fetch() async throws -> ProviderUsage {
        let env: String
        do { env = try String(contentsOf: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".env"), encoding: .utf8) }
        catch { throw AdapterError.message("无法读取 ~/.env，请检查文件权限") }
        let key = try Self.readKey(env)
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AdapterError.message("DeepSeek 连接失败，请检查网络后重试") }
        guard let http = response as? HTTPURLResponse else { throw AdapterError.message("DeepSeek 未返回有效响应") }
        switch http.statusCode {
        case 200: return try Self.parse(data)
        case 401, 403: throw AdapterError.message("DeepSeek 凭据无效或无余额查询权限，请检查 ~/.env")
        case 429: throw AdapterError.message("DeepSeek 请求过于频繁，请稍后重试")
        case 300...399: throw AdapterError.message("DeepSeek 请求发生重定向，已停止以保护凭据")
        default: throw AdapterError.message("DeepSeek 余额查询失败（HTTP \(http.statusCode)）")
        }
    }

    static func readKey(_ input: String) throws -> String {
        var result: String?
        for line in input.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let withoutExport = line.hasPrefix("export ") ? String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) : line
            guard let equals = withoutExport.firstIndex(of: "="),
                  withoutExport[..<equals].trimmingCharacters(in: .whitespaces) == "DEEPSEEK_API_KEY" else { continue }
            var value = String(withoutExport[withoutExport.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") || value.hasPrefix("'") {
                let quote = value.first!
                guard value.count >= 2, value.last == quote else { throw AdapterError.message("~/.env 中 DeepSeek 凭据格式有误") }
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.range(of: #"\s+#"#, options: .regularExpression) {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            result = value
        }
        guard let value = result, !value.isEmpty else { throw AdapterError.message("~/.env 中未找到 DEEPSEEK_API_KEY") }
        guard value.utf8.count <= 4096, value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 && $0 != "\"" && $0 != "'" && $0 != "\\" }) else {
            throw AdapterError.message("~/.env 中 DeepSeek 凭据格式有误")
        }
        return value
    }

    static func parse(_ data: Data) throws -> ProviderUsage {
        struct Response: Decodable {
            struct Entry: Decodable {
                let currency: String
                let total_balance: String
                let granted_balance: String
                let topped_up_balance: String
            }
            let is_available: Bool
            let balance_infos: [Entry]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AdapterError.message("DeepSeek 返回的余额数据格式无效")
        }
        var seen = Set<String>()
        let amounts = try response.balance_infos.map { entry -> BalanceAmount in
            guard entry.currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
                  seen.insert(entry.currency).inserted,
                  let total = decimal(entry.total_balance), let granted = decimal(entry.granted_balance),
                  let toppedUp = decimal(entry.topped_up_balance) else {
                throw AdapterError.message("DeepSeek 返回的余额数据格式无效")
            }
            return BalanceAmount(currency: entry.currency, total: total, granted: granted, toppedUp: toppedUp)
        }
        return ProviderUsage(provider: .deepseek, windows: [], updatedAt: Date(), error: nil,
                             balance: AccountBalance(isAvailable: response.is_available, amounts: amounts))
    }

    private static func decimal(_ value: String) -> Decimal? {
        guard value.count <= 64, value.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Redirects must never forward a user's Authorization header to another destination.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
