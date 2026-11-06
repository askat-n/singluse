import AppKit
import Combine
import SingluseCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Данные

/// Что сейчас играет: то же самое, что показывает плеер в Пункте управления, в любом приложении.
/// Источник — системное «Сейчас играет» через мост (Helpers/nowplaying), поэтому звуки уведомлений и
/// интерфейса сюда не попадают. Уведомления Music и Spotify — запас на случай, если будущая macOS закроет мост.
@MainActor
final class NowPlaying: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var appBundleID: String?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var duration: Double = 0
    /// Позиция на момент `positionDate`: дальше она считается сама, без постоянных запросов.
    @Published private(set) var position: Double = 0
    private var positionDate = Date()
    private var observers: [NSObjectProtocol] = []
    private var fetchedTrackKey: String?
    private static let scriptQueue = DispatchQueue(label: "Singluse.NowPlaying")
    private var bridge: Process?
    private var bridgeInput: FileHandle?
    private var bridgeFailures = 0
    private var isMonitoring = false
    /// Мост прислал хотя бы один ответ: ему можно верить, запасные источники не нужны.
    private var bridgeWorks = false
    private var systemState = SystemState()

    private struct SystemState {
        var title: String?
        var artist: String?
        var isPlaying = false
        var bundleID: String?
    }

    init() {
        let sources = [
            ("com.apple.Music.playerInfo", "com.apple.Music"),
            ("com.apple.iTunes.playerInfo", "com.apple.Music"),
            ("com.spotify.client.PlaybackStateChanged", "com.spotify.client"),
        ]
        for (name, bundleID) in sources {
            let observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                let state = info["Player State"] as? String
                let name = info["Name"] as? String
                let artist = info["Artist"] as? String
                let total = (info["Total Time"] as? Double ?? (info["Duration"] as? Double)).map { $0 / 1000 }
                let elapsed = info["Playback Position"] as? Double
                MainActor.assumeIsolated {
                    guard self?.bridgeWorks == false else { return }
                    self?.apply(state: state, title: name, artist: artist, bundleID: bundleID, total: total, elapsed: elapsed)
                }
            }
            observers.append(observer)
        }
    }

    // MARK: Мост к системному «Сейчас играет»

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        launchBridge()
    }

    func stopMonitoring() {
        isMonitoring = false
        bridge?.terminationHandler = nil
        bridge?.terminate()
        bridge = nil
        bridgeInput = nil
        bridgeWorks = false
    }

    private func launchBridge() {
        let resources = Bundle.main.resourceURL
        guard let script = resources?.appendingPathComponent("nowplaying.pl"), let library = resources?.appendingPathComponent("nowplaying.dylib"),
              FileManager.default.fileExists(atPath: library.path) else {
            syncIfRunning()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script.path, library.path]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        let reader = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in reader.append(chunk) {
                guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                let box = SendableJSON(value: json)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in self?.applyBridge(box.value) }
                }
            }
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.bridgeStopped() }
            }
        }
        do {
            try process.run()
            bridge = process
            bridgeInput = input.fileHandleForWriting
        } catch {
            NSLog("Singluse: now playing bridge failed: \(error)")
            syncIfRunning()
        }
    }

    private struct SendableJSON: @unchecked Sendable { let value: [String: Any] }

    /// Обложка не помещается в один кусок вывода, поэтому строки собираются здесь. Читает один поток.
    private final class LineBuffer: @unchecked Sendable {
        private var data = Data()

        func append(_ chunk: Data) -> [Data] {
            data.append(chunk)
            var lines: [Data] = []
            while let end = data.firstIndex(of: 0x0A) {
                lines.append(Data(data[data.startIndex..<end]))
                data.removeSubrange(data.startIndex...end)
            }
            return lines
        }
    }

    private func bridgeStopped() {
        bridge = nil
        bridgeInput = nil
        guard isMonitoring else { return }
        bridgeWorks = false
        bridgeFailures += 1
        if bridgeFailures <= 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isMonitoring else { return }
                    self.launchBridge()
                }
            }
        } else {
            NSLog("Singluse: now playing bridge gave up")
            syncIfRunning()
        }
    }

    private func applyBridge(_ json: [String: Any]) {
        guard json["error"] == nil else { return }
        bridgeWorks = true
        bridgeFailures = 0
        let name = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        systemState.title = name
        systemState.artist = (json["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (json["album"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        systemState.isPlaying = (json["playing"] as? Bool ?? (json["playing"] as? Int == 1)) && name != nil
        systemState.bundleID = Self.owner(parent: json["parent"] as? String, bundle: json["bundle"] as? String, pid: json["pid"] as? Int)
        duration = json["duration"] as? Double ?? 0
        if let elapsed = json["elapsed"] as? Double {
            position = elapsed
            positionDate = (json["stamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        } else {
            setPosition(0)
        }
        if AppSettings.shared.notchArtwork {
            if let encoded = json["artwork"] as? String, let data = Data(base64Encoded: encoded) {
                artwork = NSImage(data: data)
            } else if json["noArtwork"] != nil {
                artwork = nil
            }
        } else {
            artwork = nil
        }
        publish()
    }

    /// Браузер играет через служебный процесс, а показать нужно сам браузер.
    private static func owner(parent: String?, bundle: String?, pid: Int?) -> String? {
        for candidate in [parent, bundle].compactMap({ $0 }) {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil, !candidate.contains("WebKit") { return candidate }
        }
        if let pid, let app = NSRunningApplication(processIdentifier: pid_t(pid)), let id = app.bundleIdentifier { return id }
        return parent ?? bundle
    }

    private func publish() {
        title = systemState.title
        artist = systemState.artist
        isPlaying = systemState.isPlaying
        appBundleID = systemState.bundleID
    }

    // MARK: Кнопки

    private func send(_ command: Int, mediaKey: Int32) {
        if bridgeWorks, let bridgeInput, let data = "\(command)\n".data(using: .utf8) {
            try? bridgeInput.write(contentsOf: data)
        } else {
            Keystrokes.mediaKey(mediaKey)
        }
    }

    func togglePlayPause() { send(2, mediaKey: Keystrokes.mediaPlayPause) }
    func nextTrack() { send(4, mediaKey: Keystrokes.mediaNext) }
    func previousTrack() { send(5, mediaKey: Keystrokes.mediaPrevious) }

    /// Кнопкам нужно разрешение только там, где они работают через мультимедийные клавиши.
    var canUseButtons: Bool {
        bridgeWorks || Coordinator.shared.permissions.has(.accessibility)
    }

    /// При запуске Singluse музыка могла уже играть, а уведомление придёт только при смене трека.
    private func syncIfRunning() {
        guard AppSettings.shared.notchArtwork else { return }
        for bundleID in ["com.spotify.client", "com.apple.Music"]
        where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            fetchDetails(bundleID: bundleID, includeTrack: true)
        }
    }

    private func apply(state: String?, title newTitle: String?, artist newArtist: String?, bundleID: String, total: Double?, elapsed: Double?) {
        isPlaying = state == "Playing"
        if state == "Stopped" {
            title = nil
            artist = nil
            appBundleID = nil
            artwork = nil
            fetchedTrackKey = nil
            duration = 0
            position = 0
            return
        }
        if let newTitle { title = newTitle }
        artist = newArtist ?? artist
        appBundleID = bundleID
        if let total { duration = total }
        if let elapsed { setPosition(elapsed) }
        fetchDetails(bundleID: bundleID, includeTrack: false)
    }

    private func setPosition(_ value: Double) {
        position = value
        positionDate = Date()
    }

    func currentPosition(at date: Date) -> Double {
        let value = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return duration > 0 ? min(value, duration) : value
    }

    private func fetchDetails(bundleID: String, includeTrack: Bool) {
        guard AppSettings.shared.notchArtwork else { return }
        let key = "\(bundleID)|\(title ?? "")|\(artist ?? "")"
        let needsArtwork = key != fetchedTrackKey
        fetchedTrackKey = key
        Self.scriptQueue.async {
            let details = PlayerScript.details(bundleID: bundleID, withArtwork: needsArtwork || includeTrack)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyDetails(details, bundleID: bundleID) }
            }
        }
    }

    private func applyDetails(_ details: PlayerScript.Details?, bundleID: String) {
        guard let details else { return }
        if appBundleID == nil || title == nil {
            guard details.isPlaying else { return }
            appBundleID = bundleID
            isPlaying = true
        }
        if let value = details.title { title = value }
        if let value = details.artist { artist = value }
        if details.duration > 0 { duration = details.duration }
        setPosition(details.position)
        if let artworkData = details.artworkData {
            artwork = NSImage(data: artworkData)
        } else if let url = details.artworkURL {
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                self?.artwork = NSImage(data: data)
            }
        }
    }

    var appIcon: NSImage? {
        guard let appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Запросы к плеерам через AppleScript. Система один раз спросит разрешение на управление плеером.
private enum PlayerScript {
    struct Details: Sendable {
        var isPlaying: Bool
        var title: String?
        var artist: String?
        var position: Double
        var duration: Double
        var artworkData: Data?
        var artworkURL: URL?
    }

    static func details(bundleID: String, withArtwork: Bool) -> Details? {
        let source: String
        if bundleID == "com.spotify.client" {
            source = """
            tell application id "com.spotify.client"
                return {player state as string, name of current track, artist of current track, player position, (duration of current track) / 1000, artwork url of current track}
            end tell
            """
        } else {
            let art = withArtwork ? "try\nset artData to raw data of artwork 1 of current track\nend try" : ""
            source = """
            tell application id "com.apple.Music"
                set artData to ""
                \(art)
                return {player state as string, name of current track, artist of current track, player position, duration of current track, artData}
            end tell
            """
        }
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), result.numberOfItems >= 5 else { return nil }
        var details = Details(
            isPlaying: result.atIndex(1)?.stringValue == "playing",
            title: result.atIndex(2)?.stringValue,
            artist: result.atIndex(3)?.stringValue,
            position: result.atIndex(4)?.doubleValue ?? 0,
            duration: result.atIndex(5)?.doubleValue ?? 0
        )
        if withArtwork, let last = result.atIndex(6) {
            if bundleID == "com.spotify.client" {
                details.artworkURL = last.stringValue.flatMap(URL.init(string:))
            } else if last.descriptorType != typeUnicodeText, last.descriptorType != typeUTF8Text {
                details.artworkData = last.data
            }
        }
        return details
    }
}

/// Полка: файлы лежат на своих местах, а здесь хранится только ссылка до конца работы приложения.
@MainActor
final class FileShelf: ObservableObject {
    @Published private(set) var files: [URL] = []

    func add(_ urls: [URL]) {
        withAnimation(Motion.panel) {
            for url in urls where !files.contains(url) { files.append(url) }
        }
    }

    func remove(_ url: URL) {
        withAnimation(Motion.panel) { files.removeAll { $0 == url } }
    }

    func clear() {
        withAnimation(Motion.panel) { files.removeAll() }
    }
}

// MARK: - Форма

/// Форма чёлки: скруглена снизу, а верхние углы плавно вогнуты в край экрана.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let bottom = min(bottomRadius, h / 2)
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: topRadius, y: topRadius), control: CGPoint(x: topRadius, y: 0))
        path.addLine(to: CGPoint(x: topRadius, y: h - bottom))
        // Кривые вместо дуг дают «непрерывные» углы, как на устройствах Apple.
        path.addCurve(
            to: CGPoint(x: topRadius + bottom, y: h),
            control1: CGPoint(x: topRadius, y: h - bottom * 0.35),
            control2: CGPoint(x: topRadius + bottom * 0.35, y: h)
        )
        path.addLine(to: CGPoint(x: w - topRadius - bottom, y: h))
        path.addCurve(
            to: CGPoint(x: w - topRadius, y: h - bottom),
            control1: CGPoint(x: w - topRadius - bottom * 0.35, y: h),
            control2: CGPoint(x: w - topRadius, y: h - bottom * 0.35)
        )
        path.addLine(to: CGPoint(x: w - topRadius, y: topRadius))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - topRadius, y: 0))
        path.closeSubpath()
        return path
    }
}

// MARK: - Экземпляр на один экран

enum NotchMode: Equatable { case collapsed, activity, dictation, alert, expanded }

enum NotchPage: String, CaseIterable, Identifiable {
    case music, timer, translator, meeting, shelf, clips, ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return L("Сейчас играет")
        case .timer: return L("Таймер")
        case .translator: return L("Переводчик")
        case .meeting: return L("Запись встречи")
        case .shelf: return L("Полка для файлов")
        case .clips: return L("Буфер обмена")
        case .ai: return L("Лимиты ИИ")
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .timer: return "timer"
        case .translator: return "character.bubble.fill"
        case .meeting: return "record.circle.fill"
        case .shelf: return "tray.fill"
        case .clips: return "doc.on.clipboard.fill"
        case .ai: return "gauge.with.dots.needle.33percent"
        }
    }
}

@MainActor
final class NotchInstance: ObservableObject {
    @Published private(set) var mode: NotchMode = .collapsed
    @Published private(set) var isExpanded = false
    @Published var page: NotchPage = .music
    /// Откуда въезжает новая страница: справа при листании вперёд, слева назад.
    @Published private(set) var slidesForward = true

    static let panelSize = CGSize(width: 780, height: 340)
    static let expandedSize = CGSize(width: 440, height: 208)
    static let dictationWidth: CGFloat = 440
    static let activityExtra: CGFloat = 92

    let notchSize: CGSize
    let hasPhysicalNotch: Bool
    let screenID: CGDirectDisplayID
    private let screenFrame: CGRect
    private let panel: NSPanel
    private var enteredAt: Date?
    private var leftAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitor: Any?
    private var swipeMonitor: Any?
    private var swipeDistance: CGFloat = 0
    private var swipeUsed = false

    init(screen: NSScreen) {
        screenFrame = screen.frame
        screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let inset = screen.safeAreaInsets.top
        hasPhysicalNotch = inset > 0
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: inset)
        } else {
            // На внешнем мониторе чёлки нет — рисуем аккуратную «виртуальную» в размер строки меню.
            let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
            notchSize = CGSize(width: 170, height: min(menuBar, 32))
        }

        let size = Self.panelSize
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        panel = KeyablePanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Выше строки меню, иначе чёлку закроет её фон.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.setFrame(CGRect(origin: origin, size: size), display: false)

        let hosting = FirstMouseHostingView(rootView: NotchRootView(instance: self))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.orderFrontRegardless()

        let coordinator = Coordinator.shared
        coordinator.nowPlaying.objectWillChange
            .merge(with: coordinator.dictation.objectWillChange)
            .merge(with: coordinator.meetings.objectWillChange)
            .merge(with: coordinator.timer.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshMode() }
            .store(in: &cancellables)
        page = visiblePages.first ?? .music
        refreshMode()
        // Смахивание двумя пальцами листает страницы, как экраны на iPhone.
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleSwipe(event) == true }
            return handled ? nil : event
        }
        // Клик в другом месте закрывает чёлку сразу, даже если мышь ещё рядом.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isExpanded, self.panel.isKeyWindow else { return }
                self.setExpanded(false)
            }
        }
    }

    func close() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        cancellables.removeAll()
        panel.orderOut(nil)
        // Окно держит своё содержимое, а содержимое держит этот экземпляр. Без разрыва этой связи
        // старая чёлка оставалась в памяти и продолжала перерисовываться вместе с новой.
        panel.contentView = nil
        panel.close()
    }

    var visiblePages: [NotchPage] {
        AppSettings.shared.notchPages.compactMap(NotchPage.init(rawValue:))
    }

    func go(to newPage: NotchPage) {
        let pages = visiblePages
        guard newPage != page else { return }
        slidesForward = (pages.firstIndex(of: newPage) ?? 0) > (pages.firstIndex(of: page) ?? 0)
        withAnimation(Motion.panel) { page = newPage }
    }

    /// Одно смахивание — одна страница. Инерция после жеста страницы не листает.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard isExpanded, event.window === panel, event.hasPreciseScrollingDeltas else { return false }
        if event.phase == .began || event.phase == .mayBegin {
            swipeDistance = 0
            swipeUsed = false
        }
        guard event.momentumPhase == [] else { return swipeUsed }
        // На полке с длинным списком файлов горизонтальная прокрутка нужна самой полке.
        if page == .shelf, Coordinator.shared.shelf.files.count > 4 { return false }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard abs(dx) > abs(dy) || swipeDistance != 0 else { return false }
        // Направление пальцев, независимо от «естественной» прокрутки.
        let fingers = event.isDirectionInvertedFromDevice ? dx : -dx
        swipeDistance += fingers
        if !swipeUsed, abs(swipeDistance) > 36 {
            swipeUsed = true
            let pages = visiblePages
            if let index = pages.firstIndex(of: page) {
                let next = index + (swipeDistance < 0 ? 1 : -1)
                if pages.indices.contains(next) {
                    go(to: pages[next])
                    if AppSettings.shared.notchHaptics {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
            }
        }
        if event.phase == .ended || event.phase == .cancelled { swipeDistance = 0 }
        return true
    }

    /// Поле ввода получает клавиатуру, но приложение, в котором работает человек, остаётся активным.
    func takeKeyboard() {
        panel.makeKey()
    }

    func collapse() {
        setExpanded(false)
    }

    /// Клавиатура возвращается приложению, в котором человек работал. Окно чёлки при этом не трогаем:
    /// раньше оно на миг скрывалось и показывалось снова, и анимация закрытия дёргалась.
    private func releaseKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        if let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current {
            app.activate()
        }
        // Если система не отдала фокус сама, забираем его уже после анимации, когда рывка не видно.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isExpanded, self.panel.isKeyWindow else { return }
                self.panel.orderOut(nil)
                self.panel.orderFrontRegardless()
            }
        }
    }

    private func refreshMode() {
        let coordinator = Coordinator.shared
        let newMode: NotchMode
        switch coordinator.dictation.phase {
        case .listening, .finishing, .failed, .notice:
            // Диктовка видна только там, где курсор; на втором экране это лишний шум.
            newMode = isExpanded ? .expanded : (screenFrame.contains(NSEvent.mouseLocation) ? .dictation : .collapsed)
        case .idle:
            if isExpanded {
                if coordinator.timer.isRinging, visiblePages.contains(.timer), page != .timer { page = .timer }
                newMode = .expanded
            } else if coordinator.timer.isRinging {
                // Кнопка «Стоп» нужна там, где чёлка есть, а курсор может быть и на другом мониторе.
                newMode = .alert
            } else if coordinator.nowPlaying.isPlaying || coordinator.meetings.isRecording || coordinator.timer.isActive {
                newMode = .activity
            } else {
                newMode = .collapsed
            }
        }
        panel.ignoresMouseEvents = !(isExpanded || newMode == .alert)
        guard newMode != mode else { return }
        let opening = newMode == .expanded || newMode == .dictation || newMode == .alert
        withAnimation(opening ? Motion.island : Motion.islandClose) { mode = newMode }
    }

    private var currentSize: CGSize {
        switch mode {
        case .expanded: return Self.expandedSize
        case .dictation, .alert: return CGSize(width: Self.dictationWidth, height: notchSize.height + 46)
        case .activity: return CGSize(width: notchSize.width + Self.activityExtra, height: notchSize.height)
        case .collapsed: return notchSize
        }
    }

    private func hitRect(for size: CGSize, margin: CGFloat) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2 - margin,
            y: screenFrame.maxY - size.height - margin,
            width: size.width + margin * 2,
            height: size.height + margin + 2
        )
    }

    /// Вызывается общим таймером. Опрос нужен, потому что в свёрнутом виде панель пропускает мышь насквозь.
    func tick(mouse: CGPoint) {
        if mode == .alert { return }
        if isExpanded {
            let inside = hitRect(for: Self.expandedSize, margin: 16).contains(mouse)
            if inside {
                leftAt = nil
            } else if let leftAt {
                if Date().timeIntervalSince(leftAt) > 0.28 { setExpanded(false) }
            } else {
                leftAt = Date()
            }
        } else {
            if hitRect(for: currentSize, margin: 4).contains(mouse) {
                if let enteredAt {
                    if Date().timeIntervalSince(enteredAt) > AppSettings.shared.notchHoverDelay { setExpanded(true) }
                } else {
                    enteredAt = Date()
                }
            } else {
                enteredAt = nil
            }
        }
    }

    private func setExpanded(_ value: Bool) {
        isExpanded = value
        enteredAt = nil
        leftAt = nil
        panel.ignoresMouseEvents = !value
        if !value { releaseKeyboard() }
        if value, AppSettings.shared.notchHaptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        refreshMode()
    }
}

// MARK: - Контроллер

@MainActor
final class NotchController {
    private let settings = AppSettings.shared
    private var instances: [NotchInstance] = []
    private var isActive = false
    private var builtForAllDisplays: Bool?
    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?

    func update(active: Bool) {
        if active != isActive {
            isActive = active
            if active {
                rebuild()
                Coordinator.shared.nowPlaying.startMonitoring()
                Coordinator.shared.limits.start()
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rebuildIfScreensChanged() }
                }
            } else {
                Coordinator.shared.nowPlaying.stopMonitoring()
                Coordinator.shared.limits.stop()
                timer?.invalidate()
                timer = nil
                if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
                screenObserver = nil
                instances.forEach { $0.close() }
                instances.removeAll()
                builtForAllDisplays = nil
            }
        } else if active, builtForAllDisplays != settings.notchAllDisplays {
            rebuild()
        }
    }

    /// Экраны, для которых построены чёлки. Система сообщает об «изменении экранов» гораздо чаще,
    /// чем они на самом деле меняются, и пересоздавать чёлку каждый раз незачем.
    private var builtScreens = ""

    private static var screenSignature: String {
        NSScreen.screens.map { "\($0.stableID) \($0.frame) \($0.safeAreaInsets.top)" }.joined(separator: "|")
    }

    private func rebuildIfScreensChanged() {
        guard Self.screenSignature != builtScreens else { return }
        rebuild()
    }

    private func rebuild() {
        builtScreens = Self.screenSignature
        instances.forEach { $0.close() }
        builtForAllDisplays = settings.notchAllDisplays
        let notched = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
        let screens = (settings.notchAllDisplays || notched.isEmpty) ? NSScreen.screens : notched
        instances = screens.map { NotchInstance(screen: $0) }
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        instances.forEach { $0.tick(mouse: mouse) }
    }
}

// MARK: - Интерфейс

private struct NotchRootView: View {
    @ObservedObject var instance: NotchInstance

    private var size: CGSize {
        switch instance.mode {
        case .expanded: return NotchInstance.expandedSize
        case .dictation, .alert: return CGSize(width: NotchInstance.dictationWidth, height: instance.notchSize.height + 46)
        case .activity: return CGSize(width: instance.notchSize.width + NotchInstance.activityExtra, height: instance.notchSize.height)
        case .collapsed: return instance.notchSize
        }
    }

    var body: some View {
        let isBig = instance.mode == .expanded || instance.mode == .dictation || instance.mode == .alert
        let topRadius: CGFloat = isBig ? 16 : 7
        let bottomRadius: CGFloat = instance.mode == .expanded ? 36 : isBig ? 24 : 11
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Group {
                    switch instance.mode {
                    case .collapsed: Color.clear
                    case .activity: NotchActivityView()
                    case .dictation: NotchDictationView(topInset: instance.notchSize.height)
                    case .alert: NotchTimerAlertView(topInset: instance.notchSize.height)
                    case .expanded: NotchExpandedView(instance: instance)
                    }
                }
                .padding(.horizontal, topRadius)
                // Содержимое проявляется из лёгкого размытия, как в Dynamic Island.
                .transition(.blurReplace.combined(with: .opacity))
            }
            .frame(width: size.width, height: size.height)
            .background(shape.fill(.black))
            .clipShape(shape)
            .shadow(color: .black.opacity(isBig ? 0.4 : 0), radius: 22, y: 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

private struct Artwork: View {
    @ObservedObject var nowPlaying: NowPlaying
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack {
            if let artwork = nowPlaying.artwork {
                Image(nsImage: artwork).resizable().scaledToFill().transition(.opacity)
            } else {
                LinearGradient(colors: [.indigo, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let icon = nowPlaying.appIcon {
                    Image(nsImage: icon).resizable().frame(width: size * 0.6, height: size * 0.6)
                } else {
                    Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .animation(.smooth(duration: 0.35), value: nowPlaying.artwork)
    }
}

/// Свёрнутый вид с музыкой: обложка слева, эквалайзер справа, между ними настоящая чёлка.
private struct NotchActivityView: View {
    @ObservedObject private var nowPlaying = Coordinator.shared.nowPlaying
    @ObservedObject private var meetings = Coordinator.shared.meetings
    @ObservedObject private var timer = Coordinator.shared.timer

    var body: some View {
        HStack {
            if meetings.isRecording {
                RecordingDot()
            } else if nowPlaying.isPlaying {
                Artwork(nowPlaying: nowPlaying, size: 20, radius: 5)
            } else if timer.isRinging {
                Image(systemName: "bell.fill").font(.system(size: 13)).foregroundStyle(.orange).frame(width: 20, height: 20)
            } else {
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange).frame(width: 20, height: 20)
            }
            Spacer()
            if meetings.isRecording, let start = meetings.startDate {
                Text(start, style: .timer)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 36, alignment: .trailing)
            } else if timer.isActive {
                // Как на iPhone: оставшееся время видно всё время, а не только в раскрытой чёлке.
                TimerText(timer: timer, size: 12)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 38, alignment: .trailing)
            } else {
                EqualizerBars(isPlaying: nowPlaying.isPlaying).frame(width: 20, height: 14)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }
}

/// Красная точка записи, как на iPhone: мягко дышит, пока идёт запись.
struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(dim ? 0.45 : 1)
            .frame(width: 20, height: 20)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// Страница записи встречи: одна большая кнопка, как в «Диктофоне».
private struct MeetingPage: View {
    @ObservedObject private var meetings = Coordinator.shared.meetings

    var body: some View {
        HStack(spacing: 16) {
            Button { meetings.toggle() } label: {
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.85), lineWidth: 3).frame(width: 54, height: 54)
                    RoundedRectangle(cornerRadius: meetings.isRecording ? 5 : 21, style: .continuous)
                        .fill(.red)
                        .frame(width: meetings.isRecording ? 22 : 42, height: meetings.isRecording ? 22 : 42)
                }
                .contentShape(Circle())
                .animation(Motion.hover, value: meetings.isRecording)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(meetings.isFinishing)

            VStack(alignment: .leading, spacing: 3) {
                if meetings.isRecording, let start = meetings.startDate {
                    Text(start, style: .timer)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(meetings.current?.lines.last?.text ?? L("Слушаю…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .truncationMode(.head)
                } else if meetings.isFinishing {
                    Text("Сохраняю запись…").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                } else {
                    Text("Запись встречи").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(meetings.errorMessage ?? L("Текст сохранится в «Заметки» и в Singluse"))
                        .font(.system(size: 12))
                        .foregroundStyle(meetings.errorMessage == nil ? .white.opacity(0.6) : .orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }
}

struct EqualizerBars: View {
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let wave = (sin(time * (4 + Double(index) * 1.4) + Double(index)) + 1) / 2
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2.5, height: isPlaying ? 4 + 10 * wave : 3)
                }
            }
        }
    }
}

private struct NotchDictationView: View {
    let topInset: CGFloat
    @ObservedObject private var dictation = Coordinator.shared.dictation

    var body: some View {
        HStack(spacing: 12) {
            if case .failed(let message) = dictation.phase {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).foregroundStyle(.white).lineLimit(1)
            } else if case .notice(let message) = dictation.phase {
                Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.green)
                Text(message).foregroundStyle(.white).lineLimit(1)
            } else {
                VoiceWave(level: dictation.level, isActive: dictation.phase == .listening, color: .pink)
                Text(dictation.partialText.isEmpty ? "Говорите…" : dictation.partialText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                if dictation.phase == .finishing {
                    ProgressView().controlSize(.small).transition(.opacity)
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.top, topInset + 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Раскрытая чёлка устроена как iPhone: одна карточка на весь экран и переключатель страниц снизу.
private struct NotchExpandedView: View {
    @ObservedObject var instance: NotchInstance
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let pages = instance.visiblePages
        VStack(spacing: 0) {
            StatusRow(notchHeight: instance.notchSize.height, notchWidth: instance.notchSize.width)
            Group {
                switch instance.page {
                case .music: NowPlayingPage()
                case .timer: NotchTimerPage()
                case .translator: NotchTranslatorPage(takeKeyboard: { instance.takeKeyboard() }, close: { instance.collapse() })
                case .meeting: MeetingPage()
                case .shelf: ShelfPage()
                case .clips: ClipsPage()
                case .ai: NotchLimitsPage()
                }
            }
            .id(instance.page)
            .onChange(of: settings.notchPages) { _, _ in
                // Страницу убрали в настройках: показываем первую из оставшихся.
                if !pages.contains(instance.page), let first = instance.visiblePages.first { instance.go(to: first) }
            }
            .transition(.asymmetric(
                insertion: .move(edge: instance.slidesForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: instance.slidesForward ? .leading : .trailing).combined(with: .opacity)
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)

            if pages.count > 1 {
                HStack(spacing: 6) {
                    ForEach(pages) { page in
                        Button {
                            instance.go(to: page)
                        } label: {
                            Image(systemName: page.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(instance.page == page ? Color.black : .white.opacity(0.6))
                                .frame(width: 30, height: 20)
                                .background(Capsule().fill(.white.opacity(instance.page == page ? 1 : 0.12)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(page.title)
                    }
                }
                .padding(.bottom, 9)
            }
        }
        // Перетаскивание файла на чёлку сразу открывает полку.
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(get: { false }, set: { targeted in
            if targeted, instance.page != .shelf, pages.contains(.shelf) {
                withAnimation(Motion.panel) { instance.page = .shelf }
            }
        })) { providers in
            ShelfDrop.accept(providers)
            return true
        }
    }
}

/// Верхняя строка как статус-бар iPhone: время слева, батарея справа, чёлка посередине.
private struct StatusRow: View {
    let notchHeight: CGFloat
    let notchWidth: CGFloat
    @ObservedObject private var power = Coordinator.shared.power

    var body: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                Text(context.date.formatted(Date.FormatStyle().hour().minute()))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer(minLength: notchWidth)
            if let level = power.batteryLevel {
                HStack(spacing: 4) {
                    Text("\(level)").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    Image(systemName: power.isCharging ? "battery.100percent.bolt" : Self.symbol(level))
                        .symbolRenderingMode(.hierarchical)
                }
                .foregroundStyle(level <= 20 && !power.isCharging ? Color.red : .white)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: max(notchHeight, 26))
    }

    private static func symbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct NowPlayingPage: View {
    @ObservedObject private var nowPlaying = Coordinator.shared.nowPlaying

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Artwork(nowPlaying: nowPlaying, size: 54, radius: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlaying.title ?? "Ничего не играет")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(nowPlaying.artist ?? L("То, что в Пункте управления"))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .contentTransition(.opacity)
                Spacer(minLength: 8)
                EqualizerBars(isPlaying: nowPlaying.isPlaying).frame(width: 22, height: 16)
            }
            if nowPlaying.duration > 0 { ProgressLine(nowPlaying: nowPlaying) }
            HStack(spacing: 34) {
                mediaButton("backward.fill", nowPlaying.previousTrack, size: 17)
                mediaButton(nowPlaying.isPlaying ? "pause.fill" : "play.fill", nowPlaying.togglePlayPause, size: 25)
                mediaButton("forward.fill", nowPlaying.nextTrack, size: 17)
            }
            .disabled(!nowPlaying.canUseButtons)
            .opacity(nowPlaying.canUseButtons ? 1 : 0.35)
        }
        .padding(.horizontal, 8)
    }

    private func mediaButton(_ symbol: String, _ action: @escaping () -> Void, size: CGFloat) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Кнопка чуть уменьшается при нажатии, как элементы управления в iOS.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct ProgressLine: View {
    @ObservedObject var nowPlaying: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = nowPlaying.currentPosition(at: context.date)
            HStack(spacing: 8) {
                Text(Self.format(position))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: geometry.size.width * min(position / max(nowPlaying.duration, 1), 1))
                            .animation(.linear(duration: 1), value: position)
                    }
                }
                .frame(height: 4)
                Text(Self.format(nowPlaying.duration))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum ShelfDrop {
    @MainActor static func accept(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Coordinator.shared.shelf.add([url]) }
                }
            }
        }
    }
}

private struct ShelfPage: View {
    @ObservedObject private var shelf = Coordinator.shared.shelf

    var body: some View {
        Group {
            if shelf.files.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .light))
                    Text("Перетащите файлы сюда").font(.system(size: 13))
                }
                .foregroundStyle(.white.opacity(0.55))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.files, id: \.self) { ShelfFile(url: $0).transition(.scale.combined(with: .opacity)) }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfFile: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 46, height: 46)
            Text(url.lastPathComponent).font(.system(size: 10)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
        }
        .frame(width: 70)
        .overlay(alignment: .topTrailing) {
            Button { Coordinator.shared.shelf.remove(url) } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.black, .white)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .scaleEffect(hovering ? 1.05 : 1)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
    }
}

private struct ClipsPage: View {
    @ObservedObject private var clipboard = Coordinator.shared.clipboard

    var body: some View {
        let items = Array(clipboard.history.visible().prefix(4))
        Group {
            if items.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 24, weight: .light))
                    Text("Скопированное появится здесь").font(.system(size: 13))
                }
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        NotchClipRow(item: item) { clipboard.copyToPasteboard(item) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

private struct NotchClipRow: View {
    let item: ClipItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(ClipFormat.title(item))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Capsule())
                .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Скопировать")
    }
}

/// Служебный режим: рисует раскрытую чёлку в PNG, чтобы проверить вёрстку без наведения мыши.
@MainActor
func renderExpandedNotch(to path: String, page: String = "music") -> Bool {
    let size = NotchInstance.expandedSize
    let view = ZStack(alignment: .top) {
        NotchShape(topRadius: 16, bottomRadius: 36).fill(.black)
        VStack(spacing: 0) {
            StatusRow(notchHeight: 32, notchWidth: 185)
            Group {
                switch page {
                case "timer": NotchTimerPage()
                case "ai": NotchLimitsPage()
                case "translator": NotchTranslatorPage(takeKeyboard: {}, close: {})
                case "alert": NotchTimerAlertView(topInset: 0)
                case "activity": NotchActivityView().frame(width: 277, height: 32)
                default: NowPlayingPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 10)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }
    .frame(width: size.width, height: size.height)
    .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}
