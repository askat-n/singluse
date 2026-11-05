import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

struct SwitcherWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let appName: String
    let icon: NSImage?
    var image: NSImage?
    /// Снимка не будет: например, окно свёрнуто. Тогда вместо него значок приложения.
    var captureFailed = false

    static func == (a: SwitcherWindow, b: SwitcherWindow) -> Bool {
        a.id == b.id && a.title == b.title && a.image === b.image && a.captureFailed == b.captureFailed
    }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selection = 0
    @Published var isVisible = false
}

/// ⌥Tab: все открытые окна со всех рабочих столов, включая полноэкранные, с миниатюрами. Отпустили ⌥ — выбранное окно открылось.
@MainActor
final class WindowSwitcher {
    private let model = SwitcherModel()
    private var isActive = false
    private var panel: KeyablePanel?
    private var pollTimer: Timer?
    private var keyMonitor: Any?
    private var isSwitching = false
    private var pendingSteps = 0
    private var loadTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private var activationObserver: NSObjectProtocol?

    private static let forwardID: UInt32 = 10
    private static let backwardID: UInt32 = 11
    nonisolated private static let thumbWidth: CGFloat = 220
    nonisolated private static let thumbHeight: CGFloat = 140
    private static let columns = 5

    func update(active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            HotKeys.shared.register(id: Self.forwardID, keyCode: kVK_Tab, modifiers: UInt32(optionKey)) { [weak self] in self?.step(1) }
            HotKeys.shared.register(id: Self.backwardID, keyCode: kVK_Tab, modifiers: UInt32(optionKey | shiftKey)) { [weak self] in self?.step(-1) }
            refreshThumbnails()
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isSwitching else { return }
                    // Небольшая пауза: окно должно успеть отрисоваться.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        MainActor.assumeIsolated { self.refreshThumbnails() }
                    }
                }
            }
        } else {
            HotKeys.shared.unregister(id: Self.forwardID)
            HotKeys.shared.unregister(id: Self.backwardID)
            if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
            activationObserver = nil
            finish(commit: false)
        }
    }

    private func step(_ delta: Int) {
        guard isSwitching else {
            begin(firstStep: delta)
            return
        }
        guard !model.windows.isEmpty else {
            pendingSteps += delta
            return
        }
        move(delta)
    }

    private func move(_ delta: Int) {
        let count = model.windows.count
        guard count > 0 else { return }
        withAnimation(Motion.hover) {
            model.selection = (model.selection + delta % count + count) % count
        }
    }

    private func begin(firstStep: Int) {
        isSwitching = true
        pendingSteps = firstStep
        model.windows = []
        model.selection = 0
        // Опрос надёжнее событий: отпускание ⌥ видно, даже если фокус у другого приложения.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if !NSEvent.modifierFlags.contains(.option) { self?.optionReleased() }
            }
        }
        loadTask = Task { [weak self] in await self?.load() }
    }

    private func optionReleased() {
        // Список ещё грузится: быстрое ⌥Tab всё равно должно сработать, поэтому дожидаемся его.
        if model.windows.isEmpty, loadTask != nil { return }
        finish(commit: true)
    }

    private func load() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            loadTask = nil
            finish(commit: false)
            return
        }
        let candidates = Self.realWindows(in: content)
        // Порядок окон «от верхнего к нижнему» даёт недавние окна первыми; окна с других столов идут за окнами этого.
        let order = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = candidates.sorted {
            if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen }
            return (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max)
        }

        guard isSwitching, !Task.isCancelled else { return }
        loadTask = nil
        guard !sorted.isEmpty else {
            finish(commit: false)
            return
        }
        model.windows = sorted.map { window in
            let pid = window.owningApplication!.processID
            return SwitcherWindow(
                id: window.windowID,
                pid: pid,
                title: (window.title ?? "").isEmpty ? (window.owningApplication?.applicationName ?? "") : (window.title ?? ""),
                appName: window.owningApplication?.applicationName ?? "",
                icon: NSRunningApplication(processIdentifier: pid)?.icon,
                image: WindowOps.thumbnails[window.windowID]
            )
        }
        move(pendingSteps)
        pendingSteps = 0

        // Быстрое нажатие: ⌥ уже отпущен, панель не нужна.
        guard NSEvent.modifierFlags.contains(.option) else {
            finish(commit: true)
            return
        }
        // Показываем панель, когда снимки уже есть: человек видит окна, а не пустые плашки.
        let capture = Task { await self.captureAll(sorted) }
        if model.windows.contains(where: { $0.image == nil }) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await capture.value }
                group.addTask { try? await Task.sleep(for: .milliseconds(220)) }
                await group.next()
                group.cancelAll()
            }
        }
        guard isSwitching else { return }
        // ⌥ могли отпустить, пока снимки готовились.
        guard NSEvent.modifierFlags.contains(.option) else {
            finish(commit: true)
            return
        }
        presentPanel()
        await capture.value
        if WindowOps.thumbnails.count > 300 { WindowOps.thumbnails.removeAll() }
    }

    /// Снимает окна; неудавшиеся повторяет один раз, чтобы вместо окна не осталась пустая плашка.
    private func captureAll(_ windows: [SCWindow]) async {
        var pending = windows
        for _ in 0..<2 where !pending.isEmpty {
            var failed: [SCWindow] = []
            await withTaskGroup(of: (SCWindow, NSImage?).self) { group in
                for window in pending {
                    group.addTask { (window, await WindowOps.capture(window, height: Self.thumbHeight, maxWidth: Self.thumbWidth)) }
                }
                for await (window, image) in group {
                    guard let image else {
                        failed.append(window)
                        continue
                    }
                    WindowOps.thumbnails[window.windowID] = image
                    if let index = model.windows.firstIndex(where: { $0.id == window.windowID }) {
                        withAnimation(.smooth(duration: 0.15)) { model.windows[index].image = image }
                    }
                }
            }
            pending = failed
        }
        for window in pending {
            if let index = model.windows.firstIndex(where: { $0.id == window.windowID }), model.windows[index].image == nil {
                model.windows[index].captureFailed = true
            }
        }
    }

    /// Настоящие окна на всех столах, кроме окон самого Singluse-панелей: та же проверка, что и в превью Dock.
    private static func realWindows(in content: SCShareableContent) -> [SCWindow] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var byPID: [pid_t: WindowOps.AXWindows] = [:]
        return content.windows.filter { window in
            guard window.windowLayer == 0, window.frame.width >= 120, window.frame.height >= 80,
                  let owner = window.owningApplication, owner.processID != myPID else { return false }
            let pid = owner.processID
            let ax = byPID[pid] ?? WindowOps.axWindows(pid: pid)
            byPID[pid] = ax
            if ax.real[window.windowID] != nil { return true }
            if ax.ignored.contains(window.windowID) { return false }
            let title = window.title ?? ""
            if window.isOnScreen { return ax.real.isEmpty && !title.isEmpty }
            // Окна других столов приложение не перечисляет. Настоящее окно система держит на каком-то столе,
            // а скрытые заготовки вроде «Log In» там не числятся.
            guard !title.isEmpty || WindowOps.coversDisplay(window.frame) else { return false }
            return WindowOps.isOnHiddenSpaceOnly(window.windowID)
        }
    }

    /// Обновляет снимки заранее, когда человек переключается между приложениями: ⌥Tab сразу покажет окна.
    private func refreshThumbnails() {
        guard Date().timeIntervalSince(lastRefresh) > 3 else { return }
        lastRefresh = Date()
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            await self.captureAll(Self.realWindows(in: content))
        }
    }

    private func presentPanel() {
        let panel = ensurePanel()
        let count = model.windows.count
        let columns = min(count, Self.columns)
        let rows = Int(ceil(Double(count) / Double(Self.columns)))
        let size = NSSize(
            width: CGFloat(columns) * (Self.thumbWidth + 12) + 28,
            height: min(CGFloat(rows) * (Self.thumbHeight + 44) + 28, 720)
        )
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        withAnimation(Motion.panel) { model.isVisible = true }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape: finish(commit: false); return true
        case kVK_RightArrow: move(1); return true
        case kVK_LeftArrow: move(-1); return true
        case kVK_DownArrow: move(Self.columns); return true
        case kVK_UpArrow: move(-Self.columns); return true
        case kVK_Return: finish(commit: true); return true
        default: return false
        }
    }

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = SwitcherView(model: model) { [weak self] index in
            self?.model.selection = index
            self?.finish(commit: true)
        }
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func finish(commit: Bool) {
        guard isSwitching else { return }
        isSwitching = false
        pollTimer?.invalidate()
        pollTimer = nil
        loadTask?.cancel()
        loadTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil

        let panel = self.panel
        // Панель отдаёт фокус сразу, иначе выбранное окно стало бы активным только после ещё одного клика.
        panel?.resignKey()
        panel?.orderOut(nil)
        model.isVisible = false
        if commit, model.windows.indices.contains(model.selection) {
            let window = model.windows[model.selection]
            WindowOps.focus(id: window.id, pid: window.pid, title: window.title)
        }
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let onPick: (Int) -> Void

    var body: some View {
        ZStack {
            if model.isVisible {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 12), count: min(max(model.windows.count, 1), 5)), spacing: 12) {
                            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                                SwitcherCell(window: window, isSelected: index == model.selection)
                                    .id(index)
                                    .onTapGesture { onPick(index) }
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: model.selection) { _, value in proxy.scrollTo(value) }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SwitcherCell: View {
    let window: SwitcherWindow
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06))
                if let image = window.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(5)
                        .transition(.opacity)
                } else if window.captureFailed, let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64).transition(.opacity)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 220, height: 140)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .opacity(isSelected ? 1 : 0)
            )
            Text(window.title.isEmpty ? window.appName : window.title)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
        }
        .scaleEffect(isSelected ? 1.02 : 1)
        .animation(Motion.hover, value: isSelected)
        .contentShape(Rectangle())
    }
}
