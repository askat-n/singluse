import AppKit
import Combine
import SingluseCore

/// Единственное место, которое решает, какой модуль сейчас работает:
/// модуль запущен, только если он включён и у него есть все разрешения.
@MainActor
final class Coordinator: ObservableObject {
    static let shared = Coordinator()

    let settings = AppSettings.shared
    let permissions = Permissions()
    let power = PowerMonitor()
    let nowPlaying = NowPlaying()
    let shelf = FileShelf()
    let ai = AIManager()
    let mice = MouseMonitor()
    let whisper = WhisperEngine()
    let meetings = MeetingRecorder()
    let lockFrame = LockScreenFrame()
    let timer = NotchTimer()
    let translator = NotchTranslator()
    let limits = AILimitsMonitor()
    /// Страница настроек, которую попросили открыть из чёлки.
    @Published var requestedHubPage: HubPage?

    let wallpaper = WallpaperController()
    let scroll = SmoothScrollController()
    let clipboard = ClipboardController()
    let dictation = DictationController()
    let dock = DockPreviewController()
    let switcher = WindowSwitcher()
    let notch = NotchController()

    private var cancellables = Set<AnyCancellable>()

    func start() {
        Publishers.Merge(
            settings.objectWillChange.map { _ in () },
            permissions.objectWillChange.map { _ in () }
        )
        .merge(with: power.objectWillChange.map { _ in () })
        .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
        .sink { [weak self] in self?.reconcile() }
        .store(in: &cancellables)
        reconcile()
    }

    func openSettings(_ page: HubPage) {
        requestedHubPage = page
        (NSApp.delegate as? AppDelegate)?.showHub()
    }

    func isRunning(_ module: Module) -> Bool {
        settings.isEnabled(module) && permissions.hasAll(module.requiredPermissions)
    }

    private func reconcile() {
        wallpaper.update(active: isRunning(.wallpaper))
        lockFrame.update(active: isRunning(.wallpaper))
        scroll.update(
            active: isRunning(.scroll),
            settings: ScrollSettings(
                speed: settings.scrollSpeed,
                smoothness: settings.scrollSmoothness,
                acceleration: settings.scrollAcceleration,
                invert: settings.scrollInvert
            ),
            excluded: settings.scrollExcludedApps
        )
        clipboard.update(active: isRunning(.clipboard))
        dictation.update(active: isRunning(.dictation))
        // Модель держится в памяти, только пока она нужна; скачивание запускается лишь по кнопке.
        if isRunning(.dictation), settings.dictationEngine == "whisper" {
            if whisper.isDownloaded { whisper.prepare() }
        } else {
            whisper.unload()
        }
        dock.update(active: isRunning(.dock))
        switcher.update(active: isRunning(.dock) && settings.windowSwitcher)
        notch.update(active: isRunning(.notch))
        objectWillChange.send()
    }
}
