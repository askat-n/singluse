import AppKit
import AVFoundation
import Combine

/// Окно на уровне рабочего стола: под значками Finder, на всех Spaces, никогда не ловит клики.
private final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WallpaperController: ObservableObject {
    /// Почему обои сейчас не двигаются. Раньше причина нигде не показывалась, и обои казались сломанными.
    enum PauseReason: Equatable {
        case onBattery, lowBattery, lowPowerMode, covered
    }

    @Published private(set) var pauseReason: PauseReason?

    private let settings = AppSettings.shared
    private var windows: [WallpaperWindow] = []
    private var shaderViews: [ShaderView] = []
    /// Один плеер на источник: два экрана с одним видео показывают один и тот же кадр.
    private var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    private var isActive = false
    private var builtKey: String?
    private var observers: [NSObjectProtocol] = []
    private var rotationTimer: Timer?
    private var rotationMinutes = 0

    static let lowBatteryLevel = 20
    private static let crossfade = 0.9

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Система присылает это уведомление и без настоящих изменений; обои пересоздаются, только если экраны другие.
                guard let self, self.screensKey != Self.currentScreens else { return }
                self.rebuild(animated: false)
            }
        })
        // После сна окна и плеер надо подтолкнуть, иначе обои могут остаться на старом кадре.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild(animated: false) }
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            let isWallpaper = note.object is WallpaperWindow
            MainActor.assumeIsolated {
                guard isWallpaper else { return }
                self?.applyPlaybackState()
            }
        })
    }

    private var currentKey: String {
        let perScreen = NSScreen.screens.map { settings.source(forScreen: $0.stableID) }.joined(separator: ",")
        return "\(perScreen)|\(settings.wallpaperFPS)"
    }

    func update(active: Bool) {
        if active != isActive {
            isActive = active
            if active {
                rebuild(animated: true)
            } else {
                fadeOut(windows) { }
                windows = []
                shaderViews = []
                stopPlayer()
                builtKey = nil
                pauseReason = nil
            }
        } else if active, builtKey != currentKey {
            rebuild(animated: true)
        }
        updateRotation()
        guard active else { return }
        for view in shaderViews {
            view.speed = settings.wallpaperSpeed
            if view.renderScale != settings.wallpaperQuality {
                view.renderScale = settings.wallpaperQuality
                view.updateDrawableSize()
            }
        }
        applyPlaybackState()
    }

    private func stopPlayer() {
        players.values.forEach { $0.pause() }
        loopers = [:]
        players = [:]
    }

    /// Возвращает плеер для видео или nil, если файла больше нет.
    private func player(forVideo path: String) -> AVQueuePlayer? {
        if let existing = players[path] { return existing }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        loopers[path] = AVPlayerLooper(player: queue, templateItem: item)
        players[path] = queue
        return queue
    }

    private var screensKey = ""

    private static var currentScreens: String {
        NSScreen.screens.map { "\($0.stableID) \($0.frame)" }.joined(separator: "|")
    }

    private func rebuild(animated: Bool) {
        guard isActive else { return }
        screensKey = Self.currentScreens
        let oldWindows = windows
        let oldPlayers = players
        windows = []
        shaderViews = []
        loopers = [:]
        players = [:]
        builtKey = currentKey

        for screen in NSScreen.screens {
            let source = settings.source(forScreen: screen.stableID)
            let window = WallpaperWindow(screen: screen)
            let player = source.hasPrefix("video:") ? self.player(forVideo: String(source.dropFirst("video:".count))) : nil
            if source.hasPrefix("image:"), let image = NSImage(contentsOfFile: String(source.dropFirst("image:".count))) {
                let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.wantsLayer = true
                view.layer?.contents = image
                view.layer?.contentsGravity = .resizeAspectFill
                view.layer?.masksToBounds = true
                window.contentView = view
            } else if let player {
                let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.wantsLayer = true
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = .resizeAspectFill
                layer.frame = view.bounds
                layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                view.layer?.addSublayer(layer)
                window.contentView = view
            } else {
                // Видео удалили или переместили: показываем встроенные обои, а не чёрный экран.
                let preset = ShaderPreset(rawValue: String(source.dropFirst("shader:".count))) ?? .aurora
                let view = ShaderView(preset: preset, framesPerSecond: settings.wallpaperFPS)
                view.speed = settings.wallpaperSpeed
                view.renderScale = settings.wallpaperQuality
                window.contentView = view
                shaderViews.append(view)
            }
            window.alphaValue = animated ? 0 : 1
            window.orderFrontRegardless()
            windows.append(window)
        }
        applyPlaybackState()

        // Новые обои проявляются поверх старых, старые убираются только после этого.
        let incoming = windows
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? Self.crossfade : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incoming.forEach { $0.animator().alphaValue = 1 }
        }, completionHandler: {
            oldPlayers.values.forEach { $0.pause() }
            oldWindows.forEach(Self.discard)
            // Прозрачность нужна только на время смены: непрозрачное окно система компонует гораздо дешевле.
            incoming.forEach {
                $0.backgroundColor = .black
                $0.isOpaque = true
            }
        })
    }

    /// Убранное окно не должно рисовать дальше: шейдер останавливается, а содержимое отпускается.
    private static func discard(_ window: WallpaperWindow) {
        (window.contentView as? ShaderView)?.isPaused = true
        window.orderOut(nil)
        window.contentView = nil
    }

    private func fadeOut(_ list: [WallpaperWindow], completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            list.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            list.forEach(Self.discard)
            completion()
        })
    }

    // MARK: - Смена обоев по таймеру

    private func updateRotation() {
        let minutes = isActive ? settings.wallpaperRotateMinutes : 0
        guard minutes != rotationMinutes else { return }
        rotationMinutes = minutes
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard minutes > 0 else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotate() }
        }
    }

    private func rotate() {
        let sources = ShaderPreset.allCases.map { "shader:\($0.rawValue)" }
            + WallpaperCollection.shared.items.map(\.sourceKey)
            + settings.videoLibrary.map { "video:\($0)" }
        guard let index = sources.firstIndex(of: settings.wallpaperSource) else { return }
        settings.wallpaperSource = sources[(index + 1) % sources.count]
    }

    // MARK: - Пауза

    /// Обои останавливаются, только если на это есть причина, и эта причина видна в настройках.
    private func applyPlaybackState() {
        let power = Coordinator.shared.power
        var powerReason: PauseReason?
        if power.lowPowerMode {
            powerReason = .lowPowerMode
        } else if !settings.wallpaperOnBattery, power.onBattery {
            powerReason = .onBattery
        } else if settings.pauseOnBattery, power.onBattery, (power.batteryLevel ?? 100) < Self.lowBatteryLevel {
            powerReason = .lowBattery
        }

        var anyVisible = false
        for window in windows {
            let visible = window.occlusionState.contains(.visible)
            anyVisible = anyVisible || visible
            if let view = window.contentView as? ShaderView {
                view.setPaused(powerReason != nil || (settings.pauseWhenCovered && !visible))
            }
        }
        for player in players.values {
            if powerReason != nil || (settings.pauseWhenCovered && !anyVisible) {
                player.pause()
            } else {
                player.play()
                player.rate = Float(settings.wallpaperSpeed)
            }
        }
        let reason = powerReason ?? ((settings.pauseWhenCovered && !anyVisible && !windows.isEmpty) ? .covered : nil)
        if reason != pauseReason { pauseReason = reason }
    }
}
