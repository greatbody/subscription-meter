import Foundation
import Combine

/// User preferences only. Authentication material is stored separately by providers.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var useProviderIcons: Bool { didSet { defaults.set(useProviderIcons, forKey: "useProviderIcons") } }
    @Published var nameWidth: Double { didSet { defaults.set(nameWidth, forKey: "nameWidth") } }
    @Published var scrollSpeed: Double { didSet { defaults.set(scrollSpeed, forKey: "scrollSpeed") } }
    @Published var rotationInterval: Double { didSet { defaults.set(rotationInterval, forKey: "rotationInterval") } }
    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var githubEnabled: Bool { didSet { defaults.set(githubEnabled, forKey: "githubEnabled") } }
    @Published var chatGPTEnabled: Bool { didSet { defaults.set(chatGPTEnabled, forKey: "chatGPTEnabled") } }
    @Published var anthropicEnabled: Bool { didSet { defaults.set(anthropicEnabled, forKey: "anthropicEnabled") } }
    @Published var siliconFlowEnabled: Bool { didSet { defaults.set(siliconFlowEnabled, forKey: "siliconFlowEnabled") } }
    @Published var siliconFlowCapacity: String { didSet { defaults.set(siliconFlowCapacity, forKey: "siliconFlowCapacity") } }
    @Published var deepSeekEnabled: Bool { didSet { defaults.set(deepSeekEnabled, forKey: "deepSeekEnabled") } }
    @Published var deepSeekCapacity: String { didSet { defaults.set(deepSeekCapacity, forKey: "deepSeekCapacity") } }
    @Published var deepSeekThresholdCNY: String { didSet { defaults.set(deepSeekThresholdCNY, forKey: "deepSeekThresholdCNY") } }
    @Published var deepSeekThresholdUSD: String { didSet { defaults.set(deepSeekThresholdUSD, forKey: "deepSeekThresholdUSD") } }

    /// Balance services may opt into a user-supplied capacity independently.
    func referenceCapacity(for provider: ProviderID) -> Decimal? {
        switch provider {
        case .deepseek: return Self.parseCapacity(deepSeekCapacity)
        case .siliconflow: return Self.parseCapacity(siliconFlowCapacity)
        default: return nil
        }
    }

    static func parseCapacity(_ input: String) -> Decimal? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !number.isNaN, number > 0 else { return nil }
        return number
    }

    /// Empty or invalid input does not enable an alert; currencies never share a threshold.
    func deepSeekThreshold(for currency: String) -> Decimal? {
        switch currency.uppercased() {
        case "CNY": return Self.parseThreshold(deepSeekThresholdCNY)
        case "USD": return Self.parseThreshold(deepSeekThresholdUSD)
        default: return nil
        }
    }

    static func parseThreshold(_ input: String) -> Decimal? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^(?:[0-9]+(?:\.[0-9]{1,2})?|\.[0-9]{1,2})$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "useProviderIcons": true, "nameWidth": 88.0, "scrollSpeed": 12.0,
            "rotationInterval": 4.0, "refreshInterval": 300.0,
            "githubEnabled": true, "chatGPTEnabled": true, "anthropicEnabled": false,
            "siliconFlowEnabled": true, "siliconFlowCapacity": "",
            "deepSeekEnabled": true, "deepSeekCapacity": "", "deepSeekThresholdCNY": "", "deepSeekThresholdUSD": ""
        ])
        useProviderIcons = defaults.bool(forKey: "useProviderIcons")
        nameWidth = min(180, max(40, defaults.double(forKey: "nameWidth")))
        scrollSpeed = min(40, max(4, defaults.double(forKey: "scrollSpeed")))
        rotationInterval = min(30, max(3, defaults.double(forKey: "rotationInterval")))
        refreshInterval = min(3600, max(60, defaults.double(forKey: "refreshInterval")))
        githubEnabled = defaults.bool(forKey: "githubEnabled")
        chatGPTEnabled = defaults.bool(forKey: "chatGPTEnabled")
        anthropicEnabled = defaults.bool(forKey: "anthropicEnabled")
        siliconFlowEnabled = defaults.bool(forKey: "siliconFlowEnabled")
        siliconFlowCapacity = defaults.string(forKey: "siliconFlowCapacity") ?? ""
        deepSeekEnabled = defaults.bool(forKey: "deepSeekEnabled")
        deepSeekCapacity = defaults.string(forKey: "deepSeekCapacity") ?? ""
        deepSeekThresholdCNY = defaults.string(forKey: "deepSeekThresholdCNY") ?? ""
        deepSeekThresholdUSD = defaults.string(forKey: "deepSeekThresholdUSD") ?? ""
    }
}
