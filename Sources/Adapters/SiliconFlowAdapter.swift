import Foundation
import AppKit
import WebKit

extension Notification.Name {
    static let siliconFlowSessionUpdated = Notification.Name("SubscriptionMeter.SiliconFlowSessionUpdated")
}

enum SiliconFlowStage: String {
    case waiting, requestSeen, walletReceived, noRequest, noSubject, requestFailed, layoutMismatch, verified, loginRequired

    /// Only fixed, non-sensitive stage names may be sent by page code.
    static func fromPage(_ value: String) -> SiliconFlowStage? {
        guard let stage = SiliconFlowStage(rawValue: value), stage != .verified, stage != .loginRequired else { return nil }
        return stage
    }
    var description: String {
        switch self {
        case .waiting: return "正在等待官网钱包请求；请打开余额充值页。"
        case .requestSeen: return "已发现官网钱包请求，正在获取余额。"
        case .walletReceived: return "已收到钱包数据，正在核对页面主余额。"
        case .noRequest: return "尚未发现钱包请求；请确认余额充值页并点击“刷新网页”。"
        case .noSubject: return "已发现钱包请求但缺少必要信息，请刷新网页或重新登录。"
        case .requestFailed: return "钱包请求失败或数据格式变化，请检查登录状态后刷新网页。"
        case .layoutMismatch: return "已收到钱包数据，但页面主余额无法核对；请检查页面并重试。"
        case .verified: return "已核对通过。"
        case .loginRequired: return "请在下方官网页面登录。"
        }
    }
}

/// SiliconFlow's public /user/info endpoint is retired. The app's own WebKit session
/// reads a single strictly identified cash balance rendered by the official site.
/// It never reads or exports cookies, credentials, subject IDs, or page text.
@MainActor
final class SiliconFlowSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    static let shared = SiliconFlowSession()
    private var webView: WKWebView?
    private var window: NSWindow?
    private var latest: ProviderUsage?
    private var stage: SiliconFlowStage = .waiting
    private weak var statusLabel: NSTextField?
    private var lastRefresh = Date.distantPast
    private let trustedHost = "cloud.siliconflow.cn"
    private override init() { super.init() }

    func showLogin() {
        let webView = ensureWebView()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "硅基流动登录与现金余额"
            window.isReleasedWhenClosed = false
            window.center()
            let container = NSView()
            let hint = NSTextField(wrappingLabelWithString: "登录后请打开“余额充值”页；仅在网页主余额与钱包金额核对一致后显示，代金券不包含在内。")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .secondaryLabelColor
            hint.translatesAutoresizingMaskIntoConstraints = false
            let status = NSTextField(wrappingLabelWithString: statusText())
            status.font = .systemFont(ofSize: 12, weight: .medium)
            status.textColor = .labelColor
            status.translatesAutoresizingMaskIntoConstraints = false
            statusLabel = status
            let reload = NSButton(title: "刷新网页", target: self, action: #selector(reloadLoginPage))
            reload.translatesAutoresizingMaskIntoConstraints = false
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hint)
            container.addSubview(status)
            container.addSubview(reload)
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                hint.trailingAnchor.constraint(equalTo: reload.leadingAnchor, constant: -12),
                hint.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                reload.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                reload.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
                status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                status.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
                webView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            window.contentView = container
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func statusText() -> String {
        guard stage == .verified, let amount = latest?.balance?.amounts.first?.total else { return stage.description }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 12
        return "已核对通过：¥" + (formatter.string(from: amount as NSDecimalNumber) ?? "—") + "（现金余额）"
    }

    private func updateStage(_ next: SiliconFlowStage) {
        let changed = stage != next
        stage = next
        statusLabel?.stringValue = statusText()
        if changed { NotificationCenter.default.post(name: .siliconFlowSessionUpdated, object: nil) }
    }

    @objc private func reloadLoginPage() {
        updateStage(.waiting)
        lastRefresh = Date()
        webView?.reload()
    }

    func fetchBalance() throws -> ProviderUsage {
        let view = ensureWebView()
        let now = Date()
        if Self.needsReload(isVisible: window?.isVisible == true, isLoading: view.isLoading,
                            elapsed: now.timeIntervalSince(lastRefresh)) {
            lastRefresh = now
            view.reload()
        }
        if let latest, now.timeIntervalSince(latest.updatedAt) < 600 { return latest }
        throw AdapterError.message(stage.description)
    }

    static func needsReload(isVisible: Bool, isLoading: Bool, elapsed: TimeInterval) -> Bool {
        !isVisible && !isLoading && elapsed > 60
    }

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let content = WKUserContentController()
        content.add(self, name: "siliconCash")
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = content
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        lastRefresh = Date()
        view.load(URLRequest(url: URL(string: "https://cloud.siliconflow.cn/me/expensebill?tab=balance")!))
        return view
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        guard let url = action.request.url, url.scheme == "https", let host = url.host?.lowercased(),
              host == "siliconflow.cn" || host.hasSuffix(".siliconflow.cn") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, url.scheme == "https",
           let host = url.host?.lowercased(), host == "siliconflow.cn" || host.hasSuffix(".siliconflow.cn") {
            webView.load(action.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.host?.lowercased() == "account.siliconflow.cn" {
            latest = nil
            updateStage(.loginRequired)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "siliconCash", message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host.lowercased() == trustedHost,
              let body = message.body as? [String: Any], body.count == 1 else { return }
        if let name = body["stage"] as? String, let next = SiliconFlowStage.fromPage(name) {
            updateStage(next)
            return
        }
        guard let value = body["amount"] as? String, let amount = Self.parseCash(value) else { return }
        let balance = AccountBalance(isAvailable: nil, amounts: [BalanceAmount(currency: "CNY", total: amount, granted: nil, toppedUp: nil)])
        latest = ProviderUsage(provider: .siliconflow, windows: [], updatedAt: Date(), error: nil, balance: balance)
        // An unchanged refreshed balance can replace an expired error state too.
        let wasVerified = stage == .verified
        updateStage(.verified)
        if wasVerified { NotificationCenter.default.post(name: .siliconFlowSessionUpdated, object: nil) }
    }

    static func parseCash(_ value: String) -> Decimal? {
        guard value.count <= 40, value.range(of: #"^[0-9]+(?:\.[0-9]{1,12})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), amount >= 0 else { return nil }
        return amount
    }

    /// Replays the official same-origin wallet GET using its own in-memory session and subject header.
    /// Emits only the balance after its scale is cross-checked against the balance tab's visible amount.
    private static let script = #"""
    (() => {
      if (location.origin !== 'https://cloud.siliconflow.cn') return;
      const endpoint = 'https://cloud.siliconflow.cn/walletd-server/api/v1/subject/profile/peek';
      const nativeFetch = window.fetch;
      const tracked = new WeakMap();
      let candidate = null, posted = null, scheduled = null, requestPending = false, observedRequest = false, lastStage = null;
      const correctPage = () => location.pathname === '/me/expensebill' && new URL(location.href).searchParams.get('tab') === 'balance';
      const stage = value => {
        if (!correctPage() || lastStage === value) return;
        lastStage = value;
        window.webkit.messageHandlers.siliconCash.postMessage({stage: value});
      };
      setTimeout(() => { if (!observedRequest && !candidate) stage('noRequest'); }, 12000);
      const target = url => { try { const u = new URL(url, location.href); return u.origin === location.origin && u.pathname === '/walletd-server/api/v1/subject/profile/peek' && !u.search && !u.hash; } catch { return false; } };
      const clean = value => {
        const parts = value.split('.');
        const whole = parts[0].replace(/^0+(?=\d)/, '');
        const fractional = (parts[1] || '').replace(/0+$/, '');
        return whole + (fractional ? '.' + fractional : '');
      };
      const convert = raw => {
        if (!/^[0-9]{1,48}$/.test(raw)) return null;
        const digits = raw.replace(/^0+(?=\d)/, '').padStart(13, '0');
        const fixed = digits.slice(0, -12) + '.' + digits.slice(-12);
        return { fixed, display: clean(fixed) };
      };
      const findAmount = () => {
        if (!correctPage()) return null;
        const matches = new Set();
        for (const tab of document.querySelectorAll('[role="tab"]')) {
          if (!tab.getClientRects().length) continue;
          const text = (tab.innerText || '').trim();
          // Only the main figure immediately following the exact tab heading is accepted.
          const match = text.match(/^余额\s*[¥￥]\s*((?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?)(\.\.\.|…)?(?:\s*(?:（\s*剩余可透支额度\s*[¥￥]\s*(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?\s*）|\(\s*剩余可透支额度\s*[¥￥]\s*(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?\s*\)|剩余可透支额度\s*[¥￥]\s*(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?))?\s*$/);
          if (!match) continue;
          matches.add(JSON.stringify({shown: match[1].replace(/,/g, ''), truncated: Boolean(match[2])}));
        }
        return matches.size === 1 ? JSON.parse([...matches][0]) : null;
      };
      const verifyAndSend = () => {
        if (!candidate || !correctPage()) return;
        const shown = findAmount();
        if (!shown) return;
        let verified = false;
        if (!shown.truncated) {
          verified = clean(shown.shown) === candidate.display;
        } else {
          // A truncated prefix is useful only if it includes at least four decimal places.
          const p = shown.shown.match(/^([0-9]+)\.([0-9]{4,12})$/);
          if (p) {
            const prefix = p[1].replace(/^0+(?=\d)/, '') + '.' + p[2];
            verified = candidate.fixed.startsWith(prefix);
          }
        }
        if (verified && candidate.display !== posted) {
          posted = candidate.display;
          lastStage = 'verified';
          window.webkit.messageHandlers.siliconCash.postMessage({amount: candidate.display});
        }
      };
      const parseWallet = text => {
        try {
          const json = JSON.parse(text);
          if (!json || !json.data || !json.data.financialInfo || typeof json.data.financialInfo !== 'object') return null;
          // Recover the original integer lexeme so JS number rounding cannot alter a 1e-12 amount.
          const objects = [...text.matchAll(/"financialInfo"\s*:\s*\{([^{}]*)\}/g)];
          if (objects.length !== 1) return null;
          const values = [...objects[0][1].matchAll(/"balance"\s*:\s*("[0-9]+"|[0-9]+)(?=\s*(?:,|$))/g)];
          if (values.length !== 1) return null;
          return convert(values[0][1].replace(/^"|"$/g, ''));
        } catch { return null; }
      };
      const requestWallet = subject => {
        if (!correctPage() || requestPending) return;
        if (typeof subject !== 'string' || !/^[A-Za-z0-9._:-]{1,200}$/.test(subject)) { stage('noSubject'); return; }
        requestPending = true;
        stage('requestSeen');
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), 15000);
        nativeFetch.call(window, endpoint, {
          method: 'GET', headers: {'x-subject-id': subject}, credentials: 'same-origin',
          redirect: 'error', cache: 'no-store', signal: abort.signal
        }).then(response => {
          if (!response.ok || response.redirected || !target(response.url)) { stage('requestFailed'); return null; }
          return response.text();
        }).then(text => {
          if (!correctPage()) return;
          if (typeof text !== 'string' || text.length > 1000000) { stage('requestFailed'); return; }
          candidate = parseWallet(text);
          if (!candidate) { stage('requestFailed'); return; }
          posted = null;
          stage('walletReceived');
          verifyAndSend();
          setTimeout(() => { if (candidate && posted !== candidate.display) stage('layoutMismatch'); }, 4000);
        }).catch(() => { stage('requestFailed'); }).finally(() => { clearTimeout(timer); requestPending = false; });
      };
      window.fetch = function(input, init) {
        let subject = null, shouldWatch = false;
        try {
          const method = String((init && init.method) || (input && input.method) || 'GET').toUpperCase();
          const url = typeof input === 'string' || input instanceof URL ? String(input) : input.url;
          if (method === 'GET' && target(url)) {
            const headers = new Headers((init && init.headers) || (input && input.headers) || {});
            subject = headers.get('x-subject-id'); shouldWatch = true;
          }
        } catch {}
        const result = nativeFetch.apply(this, arguments);
        if (shouldWatch) {
          observedRequest = true;
          if (!subject) stage('noSubject');
          else result.then(response => {
            if (response.ok && !response.redirected && target(response.url)) requestWallet(subject);
            else stage('requestFailed');
          }).catch(() => { stage('requestFailed'); });
        }
        return result;
      };
      const originalOpen = XMLHttpRequest.prototype.open;
      const originalHeader = XMLHttpRequest.prototype.setRequestHeader;
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        tracked.delete(this);
        if (String(method).toUpperCase() === 'GET' && target(url)) tracked.set(this, {subject: null});
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        const record = tracked.get(this);
        if (record && String(name).toLowerCase() === 'x-subject-id') record.subject = String(value);
        return originalHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        const record = tracked.get(this);
        if (record) {
          observedRequest = true;
          this.addEventListener('load', () => {
            if (!record.subject) stage('noSubject');
            else if (this.status === 200 && target(this.responseURL)) requestWallet(record.subject);
            else stage('requestFailed');
          }, {once: true});
          this.addEventListener('error', () => { stage('requestFailed'); }, {once: true});
        }
        return originalSend.apply(this, arguments);
      };
      const schedule = () => { clearTimeout(scheduled); scheduled = setTimeout(verifyAndSend, 300); };
      const observe = () => {
        if (document.documentElement) new MutationObserver(schedule).observe(document.documentElement, {childList:true, subtree:true, characterData:true});
        schedule();
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', observe, {once:true}); else observe();
    })();
    """#
}

struct SiliconFlowAdapter: UsageAdapter {
    let provider: ProviderID = .siliconflow
    func fetch() async throws -> ProviderUsage { try await SiliconFlowSession.shared.fetchBalance() }
}
