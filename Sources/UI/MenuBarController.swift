import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar item and its transient native popover. Data fetching stays outside the UI.
@MainActor
final class MenuBarController: NSObject, ObservableObject {
    @Published private(set) var providers: [ProviderUsage] = []
    @Published private(set) var index = 0
    let settings: AppSettings
    private let item: NSStatusItem
    private var statusView: NSHostingView<StatusContent>?
    private let popover = NSPopover()
    private var rotationTimer: Timer?
    private var frameTimer: Timer?
    private var animationEnds = Date.distantPast
    private var subscriptions = Set<AnyCancellable>()
    private var lastAdvance = Date()
    private let onRefresh: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    struct Entry {
        let usage: ProviderUsage
        let window: UsageWindow?
        let amount: BalanceAmount?
    }
    var entries: [Entry] {
        providers.flatMap { provider in
            if let balance = provider.balance, !balance.amounts.isEmpty {
                return balance.amounts.map { Entry(usage: provider, window: nil, amount: $0) }
            }
            return provider.windows.isEmpty ? [Entry(usage: provider, window: nil, amount: nil)] : provider.windows.map { Entry(usage: provider, window: $0, amount: nil) }
        }
    }
    var current: Entry? { entries.indices.contains(index) ? entries[index] : entries.first }

    init(settings: AppSettings, onRefresh: @escaping () -> Void, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.settings = settings
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onQuit = onQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 370, height: 500)
        let status = NSHostingView(rootView: StatusContent(controller: self, settings: settings))
        statusView = status
        if let button = item.button {
            button.target = self
            button.action = #selector(statusButtonPressed(_:))
            // Render the hosting view outside the button; only its snapshot is
            // displayed, so stale snapshots cannot overlap the live animation.
            button.wantsLayer = true
            button.layer?.masksToBounds = true
            button.addSubview(status)
            status.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                status.leadingAnchor.constraint(equalTo: button.trailingAnchor),
                status.widthAnchor.constraint(equalTo: button.widthAnchor),
                status.topAnchor.constraint(equalTo: button.topAnchor),
                status.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }
        popover.contentViewController = NSHostingController(rootView: PanelContent(controller: self))
        settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateDisplay() }
        }.store(in: &subscriptions)
        updateDisplay()
    }
    func update(_ providers: [ProviderUsage]) {
        self.providers = providers
        if index >= entries.count { index = 0 }
        updateDisplay()
    }
    private func updateDisplay() {
        item.length = 20 + 12 + (settings.useProviderIcons ? 0 : 5 + CGFloat(settings.nameWidth))
        scheduleRotation()
        startFrames()
    }
    private func scheduleRotation() {
        rotationTimer?.invalidate()
        guard entries.count > 1 else { return }
        let delay = max(0.01, settings.rotationInterval - Date().timeIntervalSince(lastAdvance))
        rotationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }
    private func advance() {
        guard entries.count > 1 else { return }
        let next = (index + 1) % entries.count
        withAnimation(.easeInOut(duration: 0.35)) { index = next }
        lastAdvance = Date()
        animationEnds = lastAdvance.addingTimeInterval(0.45)
        scheduleRotation()
        startFrames()
    }
    private var needsMarqueeFrames: Bool {
        guard !settings.useProviderIcons, let entry = current else { return false }
        let width = settings.nameWidth - ((entry.usage.balance?.amounts.count ?? 0) > 1 ? 30 : 0)
        return (title(entry.usage.provider) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width > width
    }
    private func startFrames() {
        // Allow SwiftUI to apply state and layout changes before capturing the image.
        animationEnds = max(animationEnds, Date().addingTimeInterval(0.45))
        guard frameTimer == nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateStatusImage()
                if Date() >= self.animationEnds && !self.needsMarqueeFrames {
                    self.frameTimer?.invalidate()
                    self.frameTimer = nil
                }
            }
        }
    }
    // A native image is replicated reliably to the other menu bars.
    private func updateStatusImage() {
        guard let view = statusView, let button = item.button, view.bounds.width > 0,
              view.bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        button.image = image
    }
    @objc private func statusButtonPressed(_ sender: Any?) { togglePopover() }
    func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            // In compact mode the default centred popover arrow visually touches the ring.
            // Keep the anchor inside the status button, offset to its right edge.
            let bounds = button.bounds
            let anchor = settings.useProviderIcons
                ? NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height)
                : bounds
            popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func refresh() { onRefresh() }
    func openSettings() { popover.performClose(nil); onSettings() }
    func quit() { onQuit() }
}

private func usageColor(_ value: Double?) -> Color {
    guard let value else { return .gray }
    switch UsageLevel.forPercent(value) {
    case .critical: return Color(red: 0.84, green: 0.32, blue: 0.31)
    case .warning: return Color(red: 0.87, green: 0.60, blue: 0.24)
    case .healthy: return Color(red: 0.30, green: 0.65, blue: 0.48)
    }
}
private func title(_ provider: ProviderID) -> String {
    switch provider { case .copilot: return "GitHub Copilot"; case .codex: return "ChatGPT"; case .claude: return "Anthropic"; case .deepseek: return "DeepSeek"; case .siliconflow: return "硅基流动" }
}
private struct ProviderIcon: View {
    let provider: ProviderID
    let size: CGFloat
    private var image: NSImage? {
        let filename: String
        switch provider { case .copilot: filename = "githubcopilot"; case .codex: filename = "openai"; case .claude: filename = "claude"; case .deepseek: filename = "deepseek"; case .siliconflow: filename = "siliconflow" }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("ProviderIcons/\(filename).png"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "circle.grid.2x2").resizable().scaledToFit() }
        }.frame(width: size, height: size).accessibilityLabel(title(provider))
    }
}
private func formatMoney(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 8
    return formatter.string(from: value as NSDecimalNumber) ?? NSDecimalNumber(decimal: value).stringValue
}
private func balanceIsLow(_ balance: AccountBalance, provider: ProviderID = .deepseek, settings: AppSettings) -> Bool {
    guard provider == .deepseek else { return false }
    return balance.amounts.contains { amount in
        guard let threshold = settings.deepSeekThreshold(for: amount.currency) else { return false }
        return amount.total < threshold
    }
}
private func balanceStatus(_ balance: AccountBalance, provider: ProviderID = .deepseek, settings: AppSettings) -> String {
    if balance.isAvailable == false { return "余额不可用" }
    if balance.amounts.isEmpty { return "暂无余额明细" }
    if balance.isAvailable == nil { return "已连接" }
    return balanceIsLow(balance, provider: provider, settings: settings) ? "余额偏低" : "余额可用"
}
private let healthyColor = Color(red: 0.30, green: 0.65, blue: 0.48)
private let warningColor = Color(red: 0.87, green: 0.60, blue: 0.24)
private let criticalColor = Color(red: 0.84, green: 0.32, blue: 0.31)
private let balanceColor = Color(red: 0.25, green: 0.55, blue: 0.87)
private let aboveCapacityColor = Color(red: 0.83, green: 0.65, blue: 0.22)

// Each amount retains its original currency. The configured reference is a numeric
// comparison only; it is never used to convert or sum currencies.
private func balancePercent(_ amount: BalanceAmount, provider: ProviderID, settings: AppSettings) -> Int? {
    guard let capacity = settings.referenceCapacity(for: provider), capacity > 0 else { return nil }
    if amount.total <= 0 { return 0 }
    if amount.total >= capacity { return 100 }
    return NSDecimalNumber(decimal: amount.total / capacity * 100).intValue
}
private func balanceFraction(_ amount: BalanceAmount, provider: ProviderID, settings: AppSettings) -> Double? {
    guard let capacity = settings.referenceCapacity(for: provider), capacity > 0 else { return nil }
    let ratio = NSDecimalNumber(decimal: amount.total).dividing(by: NSDecimalNumber(decimal: capacity)).doubleValue
    return min(1, max(0, ratio))
}
private func balanceDetailColor(_ balance: AccountBalance, provider: ProviderID = .deepseek, settings: AppSettings) -> Color {
    if balance.isAvailable == false { return criticalColor }
    if balance.amounts.isEmpty { return .gray }
    return balanceIsLow(balance, provider: provider, settings: settings) ? warningColor : healthyColor
}
private func balanceIndicator(_ provider: ProviderUsage?, amount: BalanceAmount?, settings: AppSettings) -> Color {
    guard let provider, provider.error == nil, let balance = provider.balance else { return .gray }
    if balance.isAvailable == false { return criticalColor }
    guard let amount, let capacity = settings.referenceCapacity(for: provider.provider), capacity > 0 else { return .gray }
    if amount.total > capacity { return aboveCapacityColor }
    return balanceColor
}
private struct ProgressRing: View {
    let value: Double?
    let provider: ProviderID?
    let balanceColor: Color?
    let balanceFraction: Double?
    var body: some View {
        ZStack {
            Circle().inset(by: 1).stroke(Color.primary.opacity(0.16), lineWidth: 2.0)
            Circle().inset(by: 1).trim(from: 0, to: balanceColor != nil ? (balanceFraction ?? 1) : (value.map { min(1, max(0, $0 / 100)) } ?? 1))
                .stroke(balanceColor ?? usageColor(value), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let provider {
                ProviderIcon(provider: provider, size: 11)
                    .id(provider)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                    .frame(width: 13, height: 13).clipped()
            } else {
                Image(systemName: "minus").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
            }
        }.frame(width: 20, height: 20).clipped()
    }
}
private struct Marquee: View {
    let text: String
    let width: CGFloat
    let speed: Double
    @State private var offset: CGFloat = 0
    private var overflow: CGFloat {
        max(0, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width - width)
    }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).fixedSize().offset(x: offset)
            .frame(width: width, alignment: .leading).clipped()
            .onAppear(perform: start).onChange(of: text) { _ in start() }
            .onChange(of: width) { _ in start() }.onChange(of: speed) { _ in start() }
    }
    private func start() {
        offset = 0
        guard overflow > 0 else { return }
        withAnimation(.linear(duration: Double(overflow) / max(1, speed)).delay(1).repeatForever(autoreverses: false)) { offset = -overflow }
    }
}
private struct StatusContent: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var settings: AppSettings
    var body: some View {
        let entry = controller.current
        HStack(spacing: 5) {
            ProgressRing(value: entry?.usage.error == nil ? entry?.window?.usedPercent : nil, provider: entry?.usage.provider,
                         balanceColor: entry?.usage.balance != nil ? balanceIndicator(entry?.usage, amount: entry?.amount, settings: settings) : nil,
                         balanceFraction: entry.flatMap { item in item.usage.error == nil && item.usage.balance != nil ? item.amount.flatMap { balanceFraction($0, provider: item.usage.provider, settings: settings) } : nil })
            if !settings.useProviderIcons {
                ZStack(alignment: .leading) {
                    if let entry {
                        let multipleCurrencies = (entry.usage.balance?.amounts.count ?? 0) > 1
                        HStack(spacing: 3) {
                            Marquee(text: title(entry.usage.provider), width: settings.nameWidth - (multipleCurrencies ? 30 : 0), speed: settings.scrollSpeed)
                                .id(entry.usage.provider)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                            if multipleCurrencies {
                                ZStack(alignment: .leading) {
                                    Text(entry.amount?.currency ?? "").font(.system(size: 9, weight: .medium))
                                        .id(entry.amount?.currency ?? "")
                                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                                }.frame(width: 27, height: 20, alignment: .leading).clipped()
                            }
                        }
                    } else {
                        Text("未连接").font(.system(size: 11, weight: .medium))
                    }
                }.frame(width: settings.nameWidth, height: 20, alignment: .leading).clipped()
            }
        }
        .padding(.horizontal, 6).frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle()).onTapGesture { controller.togglePopover() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.map { item in
            let label = title(item.usage.provider)
            if let balance = item.usage.balance, item.usage.error == nil {
                guard let amount = item.amount else { return label + "，" + balanceStatus(balance, provider: item.usage.provider, settings: settings) }
                let amountText = "\(amount.currency) \(formatMoney(amount.total))"
                guard let percent = balancePercent(amount, provider: item.usage.provider, settings: settings) else { return label + "，" + amountText + "，" + balanceStatus(balance, provider: item.usage.provider, settings: settings) + "，未设置参考容量" }
                return label + "，" + amountText + "，" + balanceStatus(balance, provider: item.usage.provider, settings: settings) + "，参考容量的 \(percent)%"
            }
            guard item.usage.error == nil, let window = item.window else { return label + "，未连接" }
            return label + "，" + window.title + "，已使用 \(Int(floor(window.usedPercent)))%"
        } ?? "订阅用量，未连接")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.togglePopover() }
    }
}
private struct PanelContent: View {
    @ObservedObject var controller: MenuBarController
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SUBSCRIPTION METER").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                    Text("订阅用量").font(.system(size: 19, weight: .bold))
                }
                Spacer()
                Button(action: controller.refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("更新用量")
            }.padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 13)
            ScrollView {
                VStack(spacing: 9) {
                    if controller.providers.isEmpty {
                        VStack(spacing: 8) { Image(systemName: "chart.bar.xaxis").font(.title2); Text("还没有启用的订阅"); Text("在设置中选择服务并连接账户").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(controller.providers) { provider in ProviderCard(provider: provider, settings: controller.settings) }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Text("用量由各服务商提供").foregroundStyle(.secondary)
                Spacer()
                Button("设置", action: controller.openSettings).buttonStyle(.plain)
                Button("退出", action: controller.quit).buttonStyle(.plain).padding(.leading, 8)
            }.font(.system(size: 11)).padding(.horizontal, 17).padding(.vertical, 12)
        }.frame(width: 370, height: 500)
    }
}
private struct ProviderCard: View {
    let provider: ProviderUsage
    @ObservedObject var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider.provider, size: 19).frame(width: 33, height: 33).foregroundStyle(provider.provider == .codex ? Color.green : Color.white).background(provider.provider == .codex ? Color.green.opacity(0.13) : Color.primary.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(provider.provider)).font(.system(size: 13, weight: .bold))
                    Text((provider.provider == .codex ? "Codex 用量 · " : "") + "更新于 \(provider.updatedAt.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let error = provider.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
            } else if let balance = provider.balance {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(provider.provider == .deepseek ? "API 预付余额" : provider.provider == .siliconflow ? "现金余额（不含代金券）" : "账户余额").foregroundStyle(.secondary)
                        Spacer()
                        Text(balanceStatus(balance, provider: provider.provider, settings: settings)).foregroundStyle(balanceDetailColor(balance, provider: provider.provider, settings: settings)).fontWeight(.semibold)
                    }.font(.system(size: 11))
                    if balance.amounts.isEmpty {
                        Text("服务未返回币种和余额").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(balance.amounts) { amount in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(provider.provider == .deepseek ? "可用余额" : provider.provider == .siliconflow ? "现金余额" : "账户余额").font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(amount.currency) \(formatMoney(amount.total))").font(.system(size: 19, weight: .bold)).monospacedDigit()
                            }
                            if let capacity = settings.referenceCapacity(for: provider.provider), let percent = balancePercent(amount, provider: provider.provider, settings: settings) {
                                HStack {
                                    Text("参考容量 \(formatMoney(capacity))")
                                    Spacer()
                                    Text("\(percent)%")
                                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            } else {
                                Text("未设置参考容量").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if amount.toppedUp != nil || amount.granted != nil {
                                HStack {
                                    if let toppedUp = amount.toppedUp { Text("充值 \(formatMoney(toppedUp))") }
                                    if amount.toppedUp != nil && amount.granted != nil { Spacer() }
                                    if let granted = amount.granted { Text("赠金 \(formatMoney(granted))") }
                                }.font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }.padding(.top, 15)
            } else if provider.windows.isEmpty {
                Text("暂无用量数据").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 14)
            } else {
                ForEach(provider.windows) { window in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(window.title).foregroundStyle(.secondary); Spacer(); Text("\(Int(floor(window.usedPercent)))% 已使用").fontWeight(.semibold) }.font(.system(size: 11))
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    if let elapsed = window.elapsedFraction(at: context.date), elapsed > window.usedPercent / 100 {
                                        Capsule().fill(Color.primary.opacity(0.18)).frame(width: geo.size.width * elapsed)
                                    }
                                    Capsule().fill(usageColor(window.usedPercent)).frame(width: geo.size.width * CGFloat(min(1, max(0, window.usedPercent / 100))))
                                }
                            }
                        }.frame(height: 6)
                        HStack { Text(window.detail ?? "剩余 \(100 - Int(floor(window.usedPercent)))%"); Spacer(); if let date = window.resetsAt { Text("\(date.formatted(date: .abbreviated, time: .shortened)) 重置") } }.font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(.top, 15)
                }
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor).opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }
}
