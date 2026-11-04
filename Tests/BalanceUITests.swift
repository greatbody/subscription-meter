@main struct BalanceUITests {
    static func main() {
        let suite = "ink.sunrui.subscription-meter.balance-ui-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        func amount(_ currency: String, _ value: Decimal) -> BalanceAmount {
            BalanceAmount(currency: currency, total: value, granted: 0, toppedUp: value)
        }
        let cny = amount("CNY", 5), usd = amount("USD", 29)
        let available = AccountBalance(isAvailable: true, amounts: [cny, usd])
        let unavailable = AccountBalance(isAvailable: false, amounts: [cny])
        let empty = AccountBalance(isAvailable: true, amounts: [])
        func provider(_ balance: AccountBalance?, _ error: String? = nil) -> ProviderUsage {
            ProviderUsage(provider: .deepseek, windows: [], updatedAt: Date(), error: error, balance: balance)
        }
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            print("PASS: \(label)")
        }
        check(balanceFraction(cny, provider: .deepseek, settings: settings) == nil && balanceIndicator(provider(available), amount: cny, settings: settings) == .gray, "missing reference shows no invented percentage")
        settings.deepSeekCapacity = "100"
        check(balanceFraction(cny, provider: .deepseek, settings: settings) == 0.05 && balancePercent(cny, provider: .deepseek, settings: settings) == 5, "balance below capacity")
        check(balancePercent(usd, provider: .deepseek, settings: settings) == 29, "percentage precision")
        check(balancePercent(amount("CNY", 0), provider: .deepseek, settings: settings) == 0 && balanceFraction(amount("CNY", 0), provider: .deepseek, settings: settings) == 0, "zero balance is zero percent")
        check(balanceFraction(amount("CNY", 100), provider: .deepseek, settings: settings) == 1 && balanceIndicator(provider(available), amount: amount("CNY", 100), settings: settings) == balanceColor, "exact capacity is blue")
        check(balanceIndicator(provider(available), amount: amount("CNY", 90), settings: settings) == balanceColor, "90 percent balance stays blue")
        check(balanceFraction(amount("CNY", 101), provider: .deepseek, settings: settings) == 1 && balancePercent(amount("CNY", 101), provider: .deepseek, settings: settings) == 100 && balanceIndicator(provider(available), amount: amount("CNY", 101), settings: settings) == aboveCapacityColor, "above capacity is full and gold")
        check(balancePercent(cny, provider: .deepseek, settings: settings) == 5 && balancePercent(usd, provider: .deepseek, settings: settings) == 29, "currencies kept separate without conversion")
        settings.deepSeekThresholdCNY = "10"
        check(balanceIndicator(provider(available), amount: cny, settings: settings) == balanceColor && balanceIndicator(provider(available), amount: usd, settings: settings) == balanceColor && balanceStatus(available, settings: settings) == "余额偏低", "low balance status preserves blue ring")
        check(balanceIndicator(provider(unavailable), amount: cny, settings: settings) == criticalColor, "unavailable indicator")
        check(balanceIndicator(provider(nil, "error"), amount: nil, settings: settings) == .gray, "connection failure indicator")
        check(balanceStatus(empty, settings: settings) == "暂无余额明细" && balanceIndicator(provider(empty), amount: nil, settings: settings) == .gray, "empty detail indicator")
        settings.siliconFlowCapacity = "100"
        let silicon = AccountBalance(isAvailable: nil, amounts: [amount("CNY", 0)])
        let siliconProvider = ProviderUsage(provider: .siliconflow, windows: [], updatedAt: Date(), error: nil, balance: silicon)
        check(balanceStatus(silicon, provider: .siliconflow, settings: settings) == "已连接", "SiliconFlow availability remains unknown")
        check(balanceFraction(silicon.amounts[0], provider: .siliconflow, settings: settings) == 0 && balanceIndicator(siliconProvider, amount: silicon.amounts[0], settings: settings) == balanceColor, "SiliconFlow zero cash does not imply unavailable")
        check(balanceIndicator(siliconProvider, amount: amount("CNY", 101), settings: settings) == aboveCapacityColor, "SiliconFlow exceeds its own reference")
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        check(formatter.number(from: formatMoney(Decimal(string: "12.345")!))?.decimalValue == Decimal(string: "12.345"), "decimal precision preserved")
    }
}
