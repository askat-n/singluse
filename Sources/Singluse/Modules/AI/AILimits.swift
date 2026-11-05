import Foundation
import SwiftUI
import WebKit

/// Один лимит подписки: сколько израсходовано и когда он обнулится.
struct UsageWindow: Equatable, Identifiable {
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    var id: String { title }
}

/// Лимиты подписок. Сервисы показывают их только своему сайту и не дают официального API,
/// поэтому Singluse спрашивает их так же, как сама страница лимитов: из скрытого окна с вашим входом.
/// Вход выполняется на странице лимитов в настройках; его данные остаются в этом окне и никуда не передаются.
/// Эти адреса не документированы и могут измениться: тогда чёлка просто напишет, что данных нет.
@MainActor
final class AILimitsMonitor: NSObject, ObservableObject, WKNavigationDelegate {
    enum Status: Equatable { case unknown, loading, signedOut, ready, unavailable }

    @Published private(set) var windows: [AIProvider: [UsageWindow]] = [:]
    @Published private(set) var status: [AIProvider: Status] = [:]

    static let providers: [AIProvider] = [.claude, .openai]
    private var timer: Timer?
    private var lastRefresh: Date?
    private var isRefreshing = false
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Bool, Never>?

    func start() {
        guard timer == nil else { return }
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(force: Bool = false) {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefresh = Date()
        Task {
            for provider in Self.providers { await load(provider) }
            webView = nil
            isRefreshing = false
        }
    }

    private func load(_ provider: AIProvider) async {
        if windows[provider] == nil { status[provider] = .loading }
        // Лёгкая страница того же сайта: важен только адрес, от него зависит, чей вход будет использован.
        let origin = provider == .claude ? "https://claude.ai/robots.txt" : "https://chatgpt.com/robots.txt"
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = self
        webView = view
        let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            loaded = continuation
            view.load(URLRequest(url: URL(string: origin)!, timeoutInterval: 15))
        }
        guard opened else {
            status[provider] = windows[provider] == nil ? .unavailable : .ready
            return
        }
        let script = provider == .claude ? Self.claudeScript : Self.openAIScript
        let result = try? await view.callAsyncJavaScript(script, contentWorld: .defaultClient)
        guard let text = result as? String, let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            status[provider] = windows[provider] == nil ? .unavailable : .ready
            return
        }
        if json["signedOut"] as? Bool == true {
            windows[provider] = nil
            status[provider] = .signedOut
            return
        }
        let parsed = provider == .claude ? Self.parseClaude(json) : Self.parseOpenAI(json)
        if parsed.isEmpty {
            status[provider] = windows[provider] == nil ? .unavailable : .ready
        } else {
            windows[provider] = parsed
            status[provider] = .ready
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoading(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoading(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoading(false) }
    }

    private func finishLoading(_ value: Bool) {
        loaded?.resume(returning: value)
        loaded = nil
    }

    private static let claudeScript = """
    const list = await fetch('/api/organizations', {credentials: 'include'});
    if (list.status === 401 || list.status === 403) return JSON.stringify({signedOut: true});
    if (!list.ok) return JSON.stringify({error: list.status});
    const orgs = await list.json();
    const org = Array.isArray(orgs) ? (orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0]) : null;
    if (!org) return JSON.stringify({signedOut: true});
    const usage = await fetch(`/api/organizations/${org.uuid}/usage`, {credentials: 'include'});
    if (!usage.ok) return JSON.stringify({error: usage.status});
    return JSON.stringify(await usage.json());
    """

    private static let openAIScript = """
    const session = await (await fetch('/api/auth/session', {credentials: 'include'})).json();
    if (!session.accessToken) return JSON.stringify({signedOut: true});
    const usage = await fetch('/backend-api/wham/usage', {headers: {Authorization: 'Bearer ' + session.accessToken}});
    if (!usage.ok) return JSON.stringify({error: usage.status});
    return JSON.stringify(await usage.json());
    """

    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: text) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    private static func parseClaude(_ json: [String: Any]) -> [UsageWindow] {
        let known: [(String, String)] = [("five_hour", L("5 часов")), ("seven_day", L("Неделя"))]
        return known.compactMap { key, title in
            guard let window = json[key] as? [String: Any], let used = window["utilization"] as? Double else { return nil }
            return UsageWindow(title: title, usedPercent: used, resetsAt: date(window["resets_at"]))
        }
    }

    private static func parseOpenAI(_ json: [String: Any]) -> [UsageWindow] {
        guard let limits = json["rate_limit"] as? [String: Any] else { return [] }
        return ["primary_window", "secondary_window"].compactMap { key in
            guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double else { return nil }
            let seconds = window["limit_window_seconds"] as? Double ?? 0
            let title = seconds >= 86400 * 2 ? L("Неделя") : L("5 часов")
            return UsageWindow(title: title, usedPercent: used, resetsAt: date(window["reset_at"]))
        }
    }
}

/// Страница чёлки: лимиты подписок, а если подключены ключи API, то и траты.
struct NotchLimitsPage: View {
    @ObservedObject private var limits = Coordinator.shared.limits
    @ObservedObject private var ai = Coordinator.shared.ai

    var body: some View {
        let providers = AILimitsMonitor.providers.filter { limits.windows[$0] != nil }
        let spending = AIProvider.allCases.filter { ai.spend[$0] != nil && limits.windows[$0] == nil }
        Group {
            if providers.isEmpty && spending.isEmpty {
                empty
            } else {
                VStack(spacing: 7) {
                    ForEach(providers) { provider in
                        HStack(spacing: 10) {
                            Image(systemName: provider.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(provider.tint)
                                .frame(width: 18)
                            VStack(spacing: 5) {
                                ForEach(limits.windows[provider] ?? []) { window in
                                    LimitRow(window: window)
                                }
                            }
                        }
                    }
                    ForEach(spending) { provider in
                        HStack {
                            Image(systemName: provider.symbol).foregroundStyle(provider.tint).frame(width: 18)
                            Text(provider.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            Spacer()
                            Text(String(format: "$%.2f", ai.spend[provider]?.week ?? 0))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear { limits.refresh() }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 24, weight: .light))
            Text("Войдите в Claude и ChatGPT, чтобы видеть лимиты").font(.system(size: 12))
            Button("Открыть настройки") { Coordinator.shared.openSettings(.ai) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LimitRow: View {
    let window: UsageWindow

    private var color: Color {
        window.usedPercent >= 90 ? .red : window.usedPercent >= 70 ? .orange : .green
    }

    private var caption: String {
        guard let date = window.resetsAt else { return "" }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? Date.FormatStyle().hour().minute()
            : Date.FormatStyle().weekday(.abbreviated).hour().minute()
        return date.formatted(style)
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(window.title).foregroundStyle(.white.opacity(0.8))
                Text("\(Int(window.usedPercent.rounded()))%")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                Spacer()
                Text(caption).foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 11, design: .rounded))
            .monospacedDigit()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(color).frame(width: geometry.size.width * min(window.usedPercent / 100, 1))
                }
            }
            .frame(height: 4)
        }
    }
}
