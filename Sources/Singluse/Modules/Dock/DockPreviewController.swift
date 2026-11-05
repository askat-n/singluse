import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

struct WindowPreview: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    var image: NSImage?
    static func == (a: WindowPreview, b: WindowPreview) -> Bool {
        a.id == b.id && a.title == b.title && a.image === b.image
    }
}

@MainActor
final class DockPreviewModel: ObservableObject {
    @Published var isVisible = false
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var windows: [WindowPreview] = []
    /// Центр и размер карточки внутри панели, в координатах SwiftUI.
    @Published var center: CGPoint = .zero
    @Published var size: CGSize = .zero
    /// В какую сторону карточка «вырастает» из Dock.
    @Published var anchor: UnitPoint = .bottom
    var pid: pid_t = 0
    /// Finder завершать нельзя: это часть системы, в обычном Dock у него тоже нет такого пункта.
    @Published var canQuit = true
}

/// Следит за наведением на значки Dock через Accessibility и показывает окна приложения.
/// Панель занимает весь экран и прозрачна: карточка плавно перелетает от значка к значку и не обрезается.
@MainActor
final class DockPreviewController {
    private let settings = AppSettings.shared
    private let model = DockPreviewModel()
    private var isActive = false

    private var observer: AXObserver?
    private var dockList: AXUIElement?
    private var dockLaunchObserver: NSObjectProtocol?

    private var panel: KeyablePanel?
    private var trackTimer: Timer?
    private var clickMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?
    private var loadTask: Task<Void, Never>?
    private var hoveredBundleID: String?
    private var shownBundleID: String?
    private var itemFrame: CGRect = .zero
    private var cardFrame: CGRect = .zero
    private var outsideSince: Date?

    nonisolated private static let baseWidth: CGFloat = 240
    nonisolated private static let baseHeight: CGFloat = 150
    private static let maxColumns = 5

    func update(active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            attachToDock()
            // Dock перезапускается после смены настроек; наблюдателя надо ставить заново.
            dockLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.dock" else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated { self?.attachToDock() }
                }
            }
        } else {
            detachFromDock()
            hide()
            if let dockLaunchObserver { NSWorkspace.shared.notificationCenter.removeObserver(dockLaunchObserver) }
            dockLaunchObserver = nil
        }
    }

    // MARK: - Наблюдение за Dock

    private func attachToDock() {
        detachFromDock()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let appElement = AXUIElementCreateApplication(dock.processIdentifier)
        let children: [AXUIElement] = AX.attribute(appElement, kAXChildrenAttribute) ?? []
        guard let list = children.first(where: { AX.attribute($0, kAXRoleAttribute, as: String.self) == kAXListRole }) else { return }

        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let controller = Unmanaged<DockPreviewController>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { controller.selectionChanged() }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &newObserver) == .success, let newObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(newObserver, list, kAXSelectedChildrenChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        observer = newObserver
        dockList = list
    }

    private func detachFromDock() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockList = nil
    }

    private func selectionChanged() {
        hoverWork?.cancel()
        guard let dockList,
              let selected: [AXUIElement] = AX.attribute(dockList, kAXSelectedChildrenAttribute),
              let item = selected.first,
              AX.attribute(item, kAXSubroleAttribute, as: String.self) == "AXApplicationDockItem",
              let url: URL = AX.attribute(item, kAXURLAttribute),
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              !settings.dockExcludedApps.contains(bundleID),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let position = AX.point(item, kAXPositionAttribute),
              let size = AX.size(item, kAXSizeAttribute)
        else {
            // Курсор ушёл со значка. Если он не на карточке, скрываем сразу, без ожидания таймера.
            hoveredBundleID = nil
            if model.isVisible, !cardFrame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation),
               !isBetweenItemAndCard(NSEvent.mouseLocation) {
                outsideSince = Date(timeIntervalSinceNow: -1)
            }
            return
        }

        if hoveredBundleID == bundleID, shownBundleID == bundleID {
            itemFrame = appKitRect(fromQuartz: CGRect(origin: position, size: size))
            return
        }
        hoveredBundleID = bundleID
        let frame = appKitRect(fromQuartz: CGRect(origin: position, size: size))
        // Если карточка уже открыта, переход на соседний значок мгновенный, как в системном Dock.
        let delay = model.isVisible ? 0.03 : settings.dockHoverDelay
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.present(app: app, bundleID: bundleID, itemFrame: frame) }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Показ

    private func present(app: NSRunningApplication, bundleID: String, itemFrame: CGRect) {
        // Пока шла задержка, курсор мог уйти: тогда показывать уже нечего.
        guard hoveredBundleID == bundleID, itemFrame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return }
        self.itemFrame = itemFrame
        let pid = app.processIdentifier
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.load(app: app, pid: pid, bundleID: bundleID)
        }
    }

    private func load(app: NSRunningApplication, pid: pid_t, bundleID: String) async {
        // Закрытое приложение показывать незачем: значок в Dock есть, а окон нет.
        guard !app.isTerminated else {
            if model.isVisible { hide() }
            return
        }
        guard let listed = await WindowOps.windows(of: app) else { return }
        guard !Task.isCancelled, hoveredBundleID == bundleID else { return }

        // Нет окон — нет и карточки: пустые плашки только отвлекают.
        guard !listed.isEmpty else {
            if model.isVisible { hide() }
            return
        }

        shownBundleID = bundleID
        let previews = listed.map { WindowPreview(id: $0.id, title: $0.title, image: WindowOps.thumbnails[$0.id]) }
        let wasVisible = model.isVisible
        prepareForLayout(count: previews.count, resetPosition: !wasVisible)

        withAnimation(Motion.panel) {
            model.pid = pid
            model.canQuit = bundleID != "com.apple.finder"
            model.appName = app.localizedName ?? ""
            model.appIcon = app.icon
            model.windows = previews
            applyLayout(count: previews.count)
            model.isVisible = true
        }
        startTracking()

        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            let scale = settings.dockThumbScale
            for window in listed {
                guard let shareable = window.shareable else { continue }
                group.addTask { (window.id, await WindowOps.capture(shareable, height: Self.baseHeight * scale, maxWidth: Self.baseWidth * 1.25 * scale)) }
            }
            for await (id, image) in group {
                guard !Task.isCancelled, shownBundleID == bundleID else { continue }
                guard let image, let index = model.windows.firstIndex(where: { $0.id == id }) else { continue }
                WindowOps.thumbnails[id] = image
                withAnimation(.smooth(duration: 0.25)) { model.windows[index].image = image }
            }
        }
        if WindowOps.thumbnails.count > 300 { WindowOps.thumbnails.removeAll() }
    }

    private func prepareForLayout(count: Int, resetPosition: Bool) {
        let panel = ensurePanel()
        orderOutWork?.cancel()
        let screen = NSScreen.screens.first { $0.frame.intersects(itemFrame) } ?? NSScreen.screens[0]
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        if resetPosition {
            // Первое появление начинается прямо над значком, без полёта через весь экран.
            applyLayout(count: count)
        }
        panel.orderFrontRegardless()
    }

    private func applyLayout(count: Int) {
        guard let panel else { return }
        let scale = settings.dockThumbScale
        let cardWidth = Self.baseWidth * scale, cardHeight = Self.baseHeight * scale
        let titles: CGFloat = settings.dockShowTitles ? 24 : 0
        let columns = min(max(count, 1), Self.maxColumns)
        let rows = count > Self.maxColumns ? 2 : 1
        let size = CGSize(
            width: CGFloat(columns) * cardWidth + CGFloat(columns - 1) * 10 + 28,
            height: CGFloat(rows) * (cardHeight + titles) + CGFloat(rows - 1) * 10 + 66
        )

        let screen = panel.screen ?? NSScreen.screens[0]
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        let gap: CGFloat = 10
        var origin: CGPoint
        switch orientation {
        case "left":
            origin = CGPoint(x: itemFrame.maxX + gap, y: itemFrame.midY - size.height / 2)
            model.anchor = .leading
        case "right":
            origin = CGPoint(x: itemFrame.minX - size.width - gap, y: itemFrame.midY - size.height / 2)
            model.anchor = .trailing
        default:
            origin = CGPoint(x: itemFrame.midX - size.width / 2, y: itemFrame.maxY + gap)
            model.anchor = .bottom
        }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, screen.frame.minY + 8), bounds.maxY - size.height)

        cardFrame = CGRect(origin: origin, size: size)
        model.size = size
        model.center = CGPoint(x: cardFrame.midX - panel.frame.minX, y: panel.frame.maxY - cardFrame.midY)
    }

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Выше прозрачных окон других приложений (например, Wispr Flow лежит над Dock и перехватывал бы клики).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = DockPreviewView(
            model: model,
            onFocus: { [weak self] in self?.focus(windowID: $0) },
            onClose: { [weak self] in self?.close(windowID: $0) },
            onMinimize: { [weak self] in self?.minimize(windowID: $0) },
            onFullScreen: { [weak self] in self?.toggleFullScreen(windowID: $0) },
            onQuit: { [weak self] in self?.quitApp() }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    // MARK: - Отслеживание курсора и скрытие

    private func startTracking() {
        outsideSince = nil
        guard trackTimer == nil else { return }
        trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        // Клик по Dock переключает приложение; превью больше не нужно.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func track() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let overCard = cardFrame.insetBy(dx: -4, dy: -4).contains(mouse)
        // Панель прозрачна на весь экран, поэтому клики ловит только над самой карточкой.
        panel.ignoresMouseEvents = !overCard

        // Решает только положение мыши. На сообщения Dock полагаться нельзя: при уходе курсора они приходят не всегда.
        let overItem = itemFrame.insetBy(dx: -4, dy: -4).contains(mouse)
        if overCard || overItem || isBetweenItemAndCard(mouse) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) > settings.dockHideDelay { hide() }
        } else {
            outsideSince = Date()
        }
    }

    /// Мост между значком и карточкой: перевод курсора не должен её закрывать.
    private func isBetweenItemAndCard(_ point: CGPoint) -> Bool {
        // Узкий коридор ровно между значком и карточкой, а не вся их общая область.
        if itemFrame.maxY <= cardFrame.minY {
            return point.y >= itemFrame.maxY - 2 && point.y <= cardFrame.minY + 2 && abs(point.x - itemFrame.midX) < itemFrame.width / 2 + 4
        }
        if itemFrame.maxX <= cardFrame.minX {
            return point.x >= itemFrame.maxX - 2 && point.x <= cardFrame.minX + 2 && abs(point.y - itemFrame.midY) < itemFrame.height / 2 + 4
        }
        return point.x <= itemFrame.minX + 2 && point.x >= cardFrame.maxX - 2 && abs(point.y - itemFrame.midY) < itemFrame.height / 2 + 4
    }

    private func hide() {
        hoverWork?.cancel()
        loadTask?.cancel()
        trackTimer?.invalidate()
        trackTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        hoveredBundleID = nil
        shownBundleID = nil
        panel?.ignoresMouseEvents = true
        guard model.isVisible else { return }
        // Карточка уходит анимацией, панель убирается только когда та закончилась.
        withAnimation(Motion.panel) { model.isVisible = false }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isVisible else { return }
                self.panel?.orderOut(nil)
            }
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 * settings.animationScale, execute: work)
    }

    // MARK: - Действия с окнами

    private func title(of id: CGWindowID) -> String {
        model.windows.first { $0.id == id }?.title ?? ""
    }

    private func focus(windowID: CGWindowID) {
        let pid = model.pid, name = title(of: windowID)
        // Сначала убираем карточку: иначе она перехватила бы фокус у выбранного окна.
        hide()
        WindowOps.focus(id: windowID, pid: pid, title: name)
    }

    private func minimize(windowID: CGWindowID) {
        guard WindowOps.minimize(id: windowID, pid: model.pid, title: title(of: windowID)) else {
            NSSound.beep()
            return
        }
        hide()
    }

    private func toggleFullScreen(windowID: CGWindowID) {
        guard WindowOps.toggleFullScreen(id: windowID, pid: model.pid, title: title(of: windowID)) else {
            NSSound.beep()
            return
        }
        hide()
    }

    private func quitApp() {
        guard model.canQuit else { return }
        WindowOps.quit(pid: model.pid)
        hide()
    }

    private func close(windowID: CGWindowID) {
        guard WindowOps.close(id: windowID, pid: model.pid, title: title(of: windowID)) else {
            NSSound.beep()
            return
        }
        WindowOps.thumbnails[windowID] = nil
        let remaining = model.windows.filter { $0.id != windowID }
        if remaining.isEmpty {
            hide()
        } else {
            withAnimation(Motion.panel) {
                model.windows = remaining
                applyLayout(count: remaining.count)
            }
        }
    }
}

// MARK: - Интерфейс

private struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel
    @ObservedObject private var settings = AppSettings.shared
    let onFocus: (CGWindowID) -> Void
    let onClose: (CGWindowID) -> Void
    let onMinimize: (CGWindowID) -> Void
    let onFullScreen: (CGWindowID) -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if model.isVisible {
                card
                    .frame(width: model.size.width, height: model.size.height)
                    .position(model.center)
                    // Карточка растёт из значка и туда же возвращается, как окно в iOS.
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.86, anchor: model.anchor)),
                            removal: .opacity.combined(with: .scale(scale: 0.92, anchor: model.anchor))
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        let thumbWidth = 240 * settings.dockThumbScale
        let columns = Array(repeating: GridItem(.fixed(thumbWidth), spacing: 10), count: min(max(model.windows.count, 1), 5))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = model.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(model.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.opacity)
                Spacer()
                if model.canQuit {
                Button(action: onQuit) {
                    HStack(spacing: 4) {
                        Image(systemName: "power").font(.system(size: 10, weight: .bold))
                        Text("⌘Q").font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .help("Завершить приложение")
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(model.windows) { window in
                    WindowCard(window: window, icon: model.appIcon, scale: settings.dockThumbScale, showTitle: settings.dockShowTitles, onFocus: onFocus, onClose: onClose, onMinimize: onMinimize, onFullScreen: onFullScreen)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }
}

private struct WindowCard: View {
    let window: WindowPreview
    let icon: NSImage?
    let scale: Double
    let showTitle: Bool
    let onFocus: (CGWindowID) -> Void
    let onClose: (CGWindowID) -> Void
    let onMinimize: (CGWindowID) -> Void
    let onFullScreen: (CGWindowID) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06))
                    if let image = window.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(5)
                            .transition(.opacity)
                    } else if let icon {
                        // Свёрнутое окно система снять не может — показываем значок приложения.
                        Image(nsImage: icon).resizable().frame(width: 44, height: 44).opacity(0.6)
                    }
                }
                .frame(width: 240 * scale, height: 150 * scale)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(hovering ? 1 : 0)
                )

                HStack(spacing: 6) {
                    trafficButton("xmark", .red, "Закрыть окно") { onClose(window.id) }
                    trafficButton("minus", .yellow, "Свернуть окно") { onMinimize(window.id) }
                    trafficButton("arrow.up.left.and.arrow.down.right", .green, "На весь экран") { onFullScreen(window.id) }
                }
                .padding(5)
                .opacity(hovering ? 1 : 0)
                // Кнопки не должны ловить клик, пока их не видно.
                .allowsHitTesting(hovering)
            }
            if showTitle {
                Text(window.title).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 240 * scale, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onFocus(window.id) }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(Motion.hover, value: hovering)
    }

    private func trafficButton(_ symbol: String, _ color: Color, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 18, height: 18)
                .background(Circle().fill(color))
                .padding(3)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(LocalizedStringKey(help))
        .help(help)
    }
}
