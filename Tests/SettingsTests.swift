import Foundation
@main struct Check {
 static func main() {
  let domain = "meter-settings-test-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: domain)!
  defer { defaults.removePersistentDomain(forName: domain) }
  let a = AppSettings(defaults: defaults)
  precondition(a.deepSeekEnabled && a.deepSeekThreshold(for: "CNY") == nil && a.deepSeekThreshold(for: "USD") == nil)
  precondition(a.siliconFlowEnabled && a.referenceCapacity(for: .siliconflow) == nil)
  precondition(a.referenceCapacity(for: .deepseek) == nil && a.referenceCapacity(for: .copilot) == nil)
  precondition(AppSettings.parseCapacity("0") == nil && AppSettings.parseCapacity("-1") == nil && AppSettings.parseCapacity("abc") == nil)
  precondition(AppSettings.parseCapacity("0.001") == Decimal(string: "0.001"))
  a.siliconFlowCapacity = "200.75"
  a.deepSeekCapacity = "100.25"
  a.deepSeekThresholdCNY = "12.50"
  a.deepSeekThresholdUSD = "-4"
  let b = AppSettings(defaults: defaults)
  precondition(b.referenceCapacity(for: .deepseek) == Decimal(string: "100.25") && b.referenceCapacity(for: .siliconflow) == Decimal(string: "200.75") && b.referenceCapacity(for: .codex) == nil)
  precondition(b.deepSeekThreshold(for: "CNY") == Decimal(string: "12.50"))
  precondition(b.deepSeekThreshold(for: "USD") == nil && b.deepSeekThreshold(for: "EUR") == nil)
  precondition(AppSettings.parseThreshold("3.123") == nil && AppSettings.parseThreshold("abc") == nil)
  print("Settings defaults, capacity, currency isolation, validation, persistence: PASS")
 }
}
