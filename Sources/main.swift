import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    var menu: MenuBarController!
    var settingsWindow: NSWindow?
    var subscriptions = Set<AnyCancellable>()
    var timer: Timer?
    var refreshTask: Task<Void, Never>?
    var results: [ProviderID: ProviderUsage] = [:]
    var lastEnabled: [ProviderID] = []
    var lastRefreshInterval: Double = 0
    var refreshPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = MenuBarController(settings: settings, onRefresh: { [weak self] in self?.refresh() }, onSettings: { [weak self] in self?.showSettings() }, onQuit: { NSApp.terminate(nil) })
        settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.preferencesChanged() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .siliconFlowSessionUpdated)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        preferencesChanged()
        if !UserDefaults.standard.bool(forKey: "hasOpenedSettings") {
            UserDefaults.standard.set(true, forKey: "hasOpenedSettings")
            showSettings()
        }
    }
    func enabled(_ id: ProviderID) -> Bool {
        switch id { case .copilot: return settings.githubEnabled; case .codex: return settings.chatGPTEnabled; case .claude: return settings.anthropicEnabled; case .deepseek: return settings.deepSeekEnabled; case .siliconflow: return settings.siliconFlowEnabled }
    }
    func preferencesChanged() {
        if timer == nil || lastRefreshInterval != settings.refreshInterval {
            timer?.invalidate()
            lastRefreshInterval = settings.refreshInterval
            timer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        let enabledNow = ProviderID.allCases.filter(enabled)
        if enabledNow != lastEnabled {
            lastEnabled = enabledNow
            publish()
            refresh()
        }
    }
    func publish() {
        menu.update(ProviderID.allCases.filter(enabled).map { id in
            results[id] ?? ProviderUsage(provider: id, windows: [], updatedAt: Date(), error: "正在获取用量…")
        })
    }
    func refresh() {
        guard refreshTask == nil else { refreshPending = true; return }
        let adapters: [any UsageAdapter] = [CopilotAdapter(), CodexAdapter(), ClaudeAdapter(), DeepSeekAdapter(), SiliconFlowAdapter()]
        let active = adapters.filter { enabled($0.provider) }
        refreshTask = Task { [weak self] in
            await withTaskGroup(of: ProviderUsage.self) { group in
                for adapter in active {
                    group.addTask {
                        do { return try await adapter.fetch() }
                        catch { return ProviderUsage(provider: adapter.provider, windows: [], updatedAt: Date(), error: error.localizedDescription) }
                    }
                }
                for await result in group {
                    guard let self else { continue }
                    self.results[result.provider] = result
                    self.publish()
                }
            }
            self?.refreshTask = nil
            if self?.refreshPending == true { self?.refreshPending = false; self?.refresh() }
        }
    }
    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 450), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Subscription Meter 设置"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, showPanel: { [weak self] in self?.settingsWindow?.orderOut(nil); self?.menu.togglePopover() }, onSiliconFlowLogin: { SiliconFlowSession.shared.showLogin() }))
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
