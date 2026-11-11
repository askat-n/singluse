import Foundation
import SingluseCore
import SwiftUI

/// Шесть модулей приложения.
enum Module: String, CaseIterable, Identifiable {
    case wallpaper, scroll, dictation, dock, clipboard, notch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallpaper: return L("Живые обои")
        case .scroll: return L("Плавная мышь")
        case .dictation: return L("Голосовой ввод")
        case .dock: return L("Превью в Dock")
        case .clipboard: return L("Буфер обмена")
        case .notch: return L("Умная чёлка")
        }
    }

    var subtitle: String {
        switch self {
        case .wallpaper: return L("Анимированный рабочий стол")
        case .scroll: return L("Колесо мыши крутит мягко, как трекпад")
        case .dictation: return L("Зажмите клавишу, скажите, и текст появится у курсора")
        case .dock: return L("Миниатюры окон при наведении на значок")
        case .clipboard: return L("Всё скопированное всегда под рукой")
        case .notch: return L("Музыка, файлы и буфер, как Dynamic Island")
        }
    }

    var symbol: String {
        switch self {
        case .wallpaper: return "photo.fill"
        case .scroll: return "computermouse.fill"
        case .dictation: return "waveform"
        case .dock: return "dock.rectangle"
        case .clipboard: return "doc.on.clipboard.fill"
        case .notch: return "platter.filled.top.iphone"
        }
    }

    var tint: Color {
        switch self {
        case .wallpaper: return .indigo
        case .scroll: return .teal
        case .dictation: return .pink
        case .dock: return .blue
        case .clipboard: return .orange
        case .notch: return Color(white: 0.25)
        }
    }

    /// Без этих разрешений модуль работать не может.
    var requiredPermissions: [Permission] {
        switch self {
        case .wallpaper, .notch, .clipboard: return []
        case .scroll: return [.accessibility]
        case .dictation: return [.accessibility, .microphone]
        case .dock: return [.accessibility, .screenRecording]
        }
    }
}

/// Клавиша для голосового ввода.
struct DictationKey: Identifiable, Hashable {
    let keyCode: Int
    let title: String
    /// Аппаратно-зависимая маска: отличает правый Option от левого.
    let deviceMask: UInt
    var id: Int { keyCode }

    static let all = [
        DictationKey(keyCode: 61, title: L("Правый ⌥ Option"), deviceMask: 0x40),
        DictationKey(keyCode: 54, title: L("Правый ⌘ Command"), deviceMask: 0x10),
        DictationKey(keyCode: 62, title: L("Правый ⌃ Control"), deviceMask: 0x2000),
        DictationKey(keyCode: 63, title: L("fn (Глобус)"), deviceMask: 0x800000),
    ]
}

/// Готовые наборы для мыши. Первый и есть значение по умолчанию.
enum ScrollPreset: String, CaseIterable, Identifiable {
    case smoothest, balanced, fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smoothest: return L("Максимально плавно")
        case .balanced: return L("Сбалансированно")
        case .fast: return L("Быстро")
        }
    }

    var values: (speed: Double, smoothness: Double, acceleration: Double) {
        switch self {
        case .smoothest: return (1.2, 0.6, 0.2)
        case .balanced: return (1.4, 0.4, 0.3)
        case .fast: return (1.8, 0.22, 0.45)
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published private var disabledModules: Set<String> {
        didSet { d.set(Array(disabledModules), forKey: "disabledModules") }
    }

    func isEnabled(_ module: Module) -> Bool { !disabledModules.contains(module.rawValue) }

    func setEnabled(_ module: Module, _ on: Bool) {
        if on { disabledModules.remove(module.rawValue) } else { disabledModules.insert(module.rawValue) }
    }

    func binding(_ module: Module) -> Binding<Bool> {
        Binding(get: { self.isEnabled(module) }, set: { self.setEnabled(module, $0) })
    }

    var launchedBefore: Bool {
        get { d.bool(forKey: "launchedBefore") }
        set { d.set(newValue, forKey: "launchedBefore") }
    }

    // Основные
    @Published var animationScale: Double { didSet { d.set(animationScale, forKey: "animationScale") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }

    // Обои
    @Published var wallpaperSource: String { didSet { d.set(wallpaperSource, forKey: "wallpaperSource") } }
    @Published var videoLibrary: [String] { didSet { d.set(videoLibrary, forKey: "videoLibrary") } }
    @Published var wallpaperSpeed: Double { didSet { d.set(wallpaperSpeed, forKey: "wallpaperSpeed") } }
    @Published var wallpaperFPS: Int { didSet { d.set(wallpaperFPS, forKey: "wallpaperFPS") } }
    @Published var wallpaperQuality: Double { didSet { d.set(wallpaperQuality, forKey: "wallpaperQuality") } }
    @Published var wallpaperRotateMinutes: Int { didSet { d.set(wallpaperRotateMinutes, forKey: "wallpaperRotateMinutes") } }
    @Published var pauseOnBattery: Bool { didSet { d.set(pauseOnBattery, forKey: "pauseOnBattery") } }
    @Published var pauseWhenCovered: Bool { didSet { d.set(pauseWhenCovered, forKey: "pauseWhenCovered") } }

    /// Свои обои для отдельных экранов; у остальных общие `wallpaperSource`.
    @Published var wallpaperSources: [String: String] { didSet { d.set(wallpaperSources, forKey: "wallpaperSources") } }
    @Published var wallpaperFavorites: [String] { didSet { d.set(wallpaperFavorites, forKey: "wallpaperFavorites") } }
    @Published var wallpaperOnBattery: Bool { didSet { d.set(wallpaperOnBattery, forKey: "wallpaperOnBattery") } }
    @Published var wallpaperLockFrame: Bool { didSet { d.set(wallpaperLockFrame, forKey: "wallpaperLockFrame") } }
    /// Исходные картинки рабочего стола: их возвращаем, когда кадр на экране блокировки выключают.
    @Published var originalDesktopImages: [String: String] { didSet { d.set(originalDesktopImages, forKey: "originalDesktopImages") } }

    func source(forScreen id: String) -> String {
        wallpaperSources[id] ?? wallpaperSource
    }

    // Мышь
    @Published var scrollSpeed: Double { didSet { d.set(scrollSpeed, forKey: "scrollSpeed") } }
    @Published var scrollSmoothness: Double { didSet { d.set(scrollSmoothness, forKey: "scrollSmoothness") } }
    @Published var scrollAcceleration: Double { didSet { d.set(scrollAcceleration, forKey: "scrollAcceleration") } }
    @Published var scrollInvert: Bool { didSet { d.set(scrollInvert, forKey: "scrollInvert") } }
    @Published var scrollExcludedApps: [String] { didSet { d.set(scrollExcludedApps, forKey: "scrollExcludedApps") } }
    @Published var mouseProfiles: [String: WheelProfile] {
        didSet { d.set(try? JSONEncoder().encode(mouseProfiles), forKey: "mouseProfiles") }
    }

    var activeScrollPreset: ScrollPreset? {
        ScrollPreset.allCases.first {
            let v = $0.values
            return abs(v.speed - scrollSpeed) < 0.01 && abs(v.smoothness - scrollSmoothness) < 0.01 && abs(v.acceleration - scrollAcceleration) < 0.01
        }
    }

    func apply(_ preset: ScrollPreset) {
        let v = preset.values
        scrollSpeed = v.speed
        scrollSmoothness = v.smoothness
        scrollAcceleration = v.acceleration
    }

    func apply(_ profile: WheelProfile) {
        scrollSpeed = profile.speed
        scrollSmoothness = profile.smoothness
        scrollAcceleration = profile.acceleration
    }

    // Голос
    @Published var dictationKeyCode: Int { didSet { d.set(dictationKeyCode, forKey: "dictationKeyCode") } }
    @Published var dictationLocale: String { didSet { d.set(dictationLocale, forKey: "dictationLocale") } }
    /// whisper — Whisper на этом Mac; local — движок Apple; openai — облачное распознавание.
    @Published var dictationEngine: String { didSet { d.set(dictationEngine, forKey: "dictationEngine") } }
    /// off, light, formal, custom.
    @Published var dictationPolish: String { didSet { d.set(dictationPolish, forKey: "dictationPolish") } }
    @Published var dictationPolishProvider: String { didSet { d.set(dictationPolishProvider, forKey: "dictationPolishProvider") } }
    @Published var dictationCustomPrompt: String { didSet { d.set(dictationCustomPrompt, forKey: "dictationCustomPrompt") } }
    @Published var dictationVocabulary: String { didSet { d.set(dictationVocabulary, forKey: "dictationVocabulary") } }
    @Published var dictationMic: String { didSet { d.set(dictationMic, forKey: "dictationMic") } }
    @Published var dictationSound: Bool { didSet { d.set(dictationSound, forKey: "dictationSound") } }
    /// Второй язык речи: код вроде "en". Пустая строка — только основной язык.
    @Published var dictationSecondLanguage: String { didSet { d.set(dictationSecondLanguage, forKey: "dictationSecondLanguage") } }
    @Published var dictationInstant: Bool { didSet { d.set(dictationInstant, forKey: "dictationInstant") } }
    @Published var dictationKeepHistory: Bool { didSet { d.set(dictationKeepHistory, forKey: "dictationKeepHistory") } }
    /// Стиль по приложениям: идентификатор приложения → WritingStyle.
    @Published var appStyles: [String: String] { didSet { d.set(appStyles, forKey: "appStyles") } }

    func style(for bundleID: String?) -> WritingStyle {
        guard let bundleID, let raw = appStyles[bundleID] else { return .standard }
        return WritingStyle(rawValue: raw) ?? .standard
    }

    var vocabularyTerms: [String] {
        dictationVocabulary.split(whereSeparator: { ",\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // Dock
    @Published var dockHoverDelay: Double { didSet { d.set(dockHoverDelay, forKey: "dockHoverDelay") } }
    @Published var dockHideDelay: Double { didSet { d.set(dockHideDelay, forKey: "dockHideDelay") } }
    @Published var dockThumbScale: Double { didSet { d.set(dockThumbScale, forKey: "dockThumbScale") } }
    @Published var dockShowTitles: Bool { didSet { d.set(dockShowTitles, forKey: "dockShowTitles") } }
    @Published var dockExcludedApps: [String] { didSet { d.set(dockExcludedApps, forKey: "dockExcludedApps") } }

    @Published var windowSwitcher: Bool { didSet { d.set(windowSwitcher, forKey: "windowSwitcher") } }

    // Буфер
    @Published var clipLimit: Int { didSet { d.set(clipLimit, forKey: "clipLimit") } }
    @Published var clipRetentionDays: Int { didSet { d.set(clipRetentionDays, forKey: "clipRetentionDays") } }
    @Published var clipExcludedApps: [String] { didSet { d.set(clipExcludedApps, forKey: "clipExcludedApps") } }
    @Published var clipHotkey: Int { didSet { d.set(clipHotkey, forKey: "clipHotkey") } }

    // Чёлка
    @Published var notchAllDisplays: Bool { didSet { d.set(notchAllDisplays, forKey: "notchAllDisplays") } }
    @Published var notchPages: [String] { didSet { d.set(notchPages, forKey: "notchPages") } }
    @Published var notchHoverDelay: Double { didSet { d.set(notchHoverDelay, forKey: "notchHoverDelay") } }
    @Published var notchHaptics: Bool { didSet { d.set(notchHaptics, forKey: "notchHaptics") } }
    @Published var notchArtwork: Bool { didSet { d.set(notchArtwork, forKey: "notchArtwork") } }
    @Published var timerPresets: [Int] { didSet { d.set(timerPresets, forKey: "timerPresets") } }
    @Published var timerSound: String { didSet { d.set(timerSound, forKey: "timerSound") } }
    @Published var translatorLanguages: [String] { didSet { d.set(translatorLanguages, forKey: "translatorLanguages") } }
    @Published var translatorSource: String { didSet { d.set(translatorSource, forKey: "translatorSource") } }
    @Published var translatorTarget: String { didSet { d.set(translatorTarget, forKey: "translatorTarget") } }

    private static let defaults: [String: Any] = [
        "animationScale": 1.0,
        "showMenuBarIcon": true,
        "wallpaperSource": "shader:aurora",
        "wallpaperSpeed": 1.0,
        "wallpaperFPS": 60,
        "wallpaperQuality": 0.5,
        "wallpaperRotateMinutes": 0,
        "pauseOnBattery": true,
        "wallpaperOnBattery": true,
        "wallpaperLockFrame": false,
        "pauseWhenCovered": true,
        "scrollSpeed": 1.2,
        "scrollSmoothness": 0.6,
        "scrollAcceleration": 0.2,
        "scrollInvert": false,
        "dictationKeyCode": 61,
        "dictationLocale": "ru-RU",
        "dictationEngine": "whisper",
        "dictationPolish": "off",
        "dictationPolishProvider": "claude",
        "dictationCustomPrompt": "",
        "dictationVocabulary": "",
        "dictationMic": "",
        "dictationSound": true,
        "dictationKeepHistory": true,
        "dictationInstant": true,
        "appStyles": [
            "com.apple.mail": "business",
            "com.microsoft.Outlook": "business",
            "ru.keepcoder.Telegram": "casual",
            "org.telegram.desktop": "casual",
            "net.whatsapp.WhatsApp": "casual",
            "com.apple.MobileSMS": "casual",
            "com.hnc.Discord": "casual",
            "com.tinyspeck.slackmacgap": "casual",
        ],
        "dockHoverDelay": 0.12,
        "dockHideDelay": 0.06,
        "windowSwitcher": true,
        "dockThumbScale": 1.0,
        "dockShowTitles": true,
        "clipLimit": 200,
        "clipRetentionDays": 0,
        "clipHotkey": 0,
        "notchAllDisplays": true,
        "notchPages": ["music", "timer", "translator", "meeting", "shelf", "clips", "ai"],
        "timerPresets": [5, 10, 20],
        "timerSound": "Glass",
        "translatorLanguages": ["ru", "en"],
        "translatorSource": "auto",
        "translatorTarget": "en",
        "notchHoverDelay": 0.1,
        "notchHaptics": true,
        "notchArtwork": true,
    ]

    private init() {
        d.register(defaults: Self.defaults)
        disabledModules = Set(d.stringArray(forKey: "disabledModules") ?? [])
        animationScale = d.double(forKey: "animationScale")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        wallpaperSource = d.string(forKey: "wallpaperSource") ?? "shader:aurora"
        videoLibrary = d.stringArray(forKey: "videoLibrary") ?? []
        wallpaperSpeed = d.double(forKey: "wallpaperSpeed")
        wallpaperFPS = d.integer(forKey: "wallpaperFPS")
        wallpaperQuality = d.double(forKey: "wallpaperQuality")
        wallpaperRotateMinutes = d.integer(forKey: "wallpaperRotateMinutes")
        pauseOnBattery = d.bool(forKey: "pauseOnBattery")
        wallpaperSources = d.dictionary(forKey: "wallpaperSources") as? [String: String] ?? [:]
        wallpaperFavorites = d.stringArray(forKey: "wallpaperFavorites") ?? []
        wallpaperOnBattery = d.bool(forKey: "wallpaperOnBattery")
        wallpaperLockFrame = d.bool(forKey: "wallpaperLockFrame")
        originalDesktopImages = d.dictionary(forKey: "originalDesktopImages") as? [String: String] ?? [:]
        pauseWhenCovered = d.bool(forKey: "pauseWhenCovered")
        scrollSpeed = d.double(forKey: "scrollSpeed")
        scrollSmoothness = d.double(forKey: "scrollSmoothness")
        scrollAcceleration = d.double(forKey: "scrollAcceleration")
        scrollInvert = d.bool(forKey: "scrollInvert")
        scrollExcludedApps = d.stringArray(forKey: "scrollExcludedApps") ?? []
        mouseProfiles = d.data(forKey: "mouseProfiles").flatMap { try? JSONDecoder().decode([String: WheelProfile].self, from: $0) } ?? [:]
        dictationKeyCode = d.integer(forKey: "dictationKeyCode")
        dictationLocale = d.string(forKey: "dictationLocale") ?? "ru-RU"
        dictationEngine = d.string(forKey: "dictationEngine") ?? "whisper"
        dictationPolish = d.string(forKey: "dictationPolish") ?? "off"
        dictationPolishProvider = d.string(forKey: "dictationPolishProvider") ?? "claude"
        dictationCustomPrompt = d.string(forKey: "dictationCustomPrompt") ?? ""
        dictationVocabulary = d.string(forKey: "dictationVocabulary") ?? ""
        dictationMic = d.string(forKey: "dictationMic") ?? ""
        dictationSound = d.bool(forKey: "dictationSound")
        dictationKeepHistory = d.bool(forKey: "dictationKeepHistory")
        dictationInstant = d.bool(forKey: "dictationInstant")
        appStyles = d.dictionary(forKey: "appStyles") as? [String: String] ?? [:]
        if let second = d.string(forKey: "dictationSecondLanguage") {
            dictationSecondLanguage = second
        } else {
            // Первый запуск с двумя языками: человек просил русский и английский вместе.
            dictationSecondLanguage = "en"
            dictationLocale = "ru-RU"
            d.set("en", forKey: "dictationSecondLanguage")
            d.set("ru-RU", forKey: "dictationLocale")
        }
        dockHoverDelay = d.double(forKey: "dockHoverDelay")
        dockHideDelay = d.double(forKey: "dockHideDelay")
        dockThumbScale = d.double(forKey: "dockThumbScale")
        dockShowTitles = d.bool(forKey: "dockShowTitles")
        windowSwitcher = d.bool(forKey: "windowSwitcher")
        dockExcludedApps = d.stringArray(forKey: "dockExcludedApps") ?? []
        clipLimit = d.integer(forKey: "clipLimit")
        clipRetentionDays = d.integer(forKey: "clipRetentionDays")
        clipExcludedApps = d.stringArray(forKey: "clipExcludedApps") ?? []
        clipHotkey = d.integer(forKey: "clipHotkey")
        notchAllDisplays = d.bool(forKey: "notchAllDisplays")
        notchPages = d.stringArray(forKey: "notchPages") ?? ["music", "meeting", "shelf", "clips", "ai"]
        notchHoverDelay = d.double(forKey: "notchHoverDelay")
        notchHaptics = d.bool(forKey: "notchHaptics")
        notchArtwork = d.bool(forKey: "notchArtwork")
        timerPresets = (d.array(forKey: "timerPresets") as? [Int]) ?? [5, 10, 20]
        timerSound = d.string(forKey: "timerSound") ?? "Glass"
        translatorLanguages = d.stringArray(forKey: "translatorLanguages") ?? ["ru", "en"]
        translatorSource = d.string(forKey: "translatorSource") ?? "auto"
        translatorTarget = d.string(forKey: "translatorTarget") ?? "en"

        // Разовые правки сохранённых настроек по явным просьбам: скрывать превью сразу и показать запись встречи в чёлке.
        if !d.bool(forKey: "migratedV3") {
            d.set(true, forKey: "migratedV3")
            dockHideDelay = 0.06
            if !notchPages.contains("meeting") {
                let order = ["music", "meeting", "shelf", "clips", "ai"]
                notchPages = order.filter { notchPages.contains($0) || $0 == "meeting" }
            }
        }
        // Новая физика прокрутки: старые значения мягкости давали долгий хвост после остановки колеса.
        if !d.bool(forKey: "migratedScrollV2") {
            d.set(true, forKey: "migratedScrollV2")
            scrollSmoothness = min(scrollSmoothness, 0.6)
            scrollAcceleration = min(scrollAcceleration, 0.2)
            mouseProfiles = mouseProfiles.mapValues { profile in
                var profile = profile
                profile.smoothness = min(profile.smoothness, profile.kind == .notched ? 0.6 : 0.4)
                profile.acceleration = min(profile.acceleration, 0.2)
                return profile
            }
        }
        // Новые страницы чёлки появляются сами, остальной выбор человека не меняется.
        if !d.bool(forKey: "migratedV4") {
            d.set(true, forKey: "migratedV4")
            let order = NotchPage.allCases.map(\.rawValue)
            notchPages = order.filter { notchPages.contains($0) || $0 == "timer" || $0 == "translator" }
        }
    }

    /// Возвращает настройки модуля к значениям по умолчанию. Выбранные файлы и профили мышей остаются.
    func reset(_ module: Module) {
        func double(_ key: String) -> Double { Self.defaults[key] as! Double }
        func bool(_ key: String) -> Bool { Self.defaults[key] as! Bool }
        func int(_ key: String) -> Int { Self.defaults[key] as! Int }
        switch module {
        case .wallpaper:
            wallpaperSpeed = double("wallpaperSpeed")
            wallpaperFPS = int("wallpaperFPS")
            wallpaperQuality = double("wallpaperQuality")
            wallpaperRotateMinutes = int("wallpaperRotateMinutes")
            pauseOnBattery = bool("pauseOnBattery")
            wallpaperOnBattery = bool("wallpaperOnBattery")
            pauseWhenCovered = bool("pauseWhenCovered")
        case .scroll:
            apply(.smoothest)
            scrollInvert = false
            scrollExcludedApps = []
        case .dictation:
            dictationKeyCode = int("dictationKeyCode")
            dictationEngine = "whisper"
            dictationPolish = "off"
            dictationSound = bool("dictationSound")
            dictationInstant = bool("dictationInstant")
            dictationMic = ""
        case .dock:
            dockHoverDelay = double("dockHoverDelay")
            dockHideDelay = double("dockHideDelay")
            dockThumbScale = double("dockThumbScale")
            dockShowTitles = bool("dockShowTitles")
            dockExcludedApps = []
            windowSwitcher = bool("windowSwitcher")
        case .clipboard:
            clipLimit = int("clipLimit")
            clipRetentionDays = int("clipRetentionDays")
            clipHotkey = int("clipHotkey")
            clipExcludedApps = []
        case .notch:
            notchAllDisplays = bool("notchAllDisplays")
            notchPages = Self.defaults["notchPages"] as! [String]
            notchHoverDelay = double("notchHoverDelay")
            notchHaptics = bool("notchHaptics")
            notchArtwork = bool("notchArtwork")
            timerPresets = Self.defaults["timerPresets"] as! [Int]
            timerSound = Self.defaults["timerSound"] as! String
        }
    }
}

/// Единый характер движения всего приложения: пружины Apple без резких остановок.
enum Motion {
    @MainActor private static var scale: Double { AppSettings.shared.animationScale }

    /// Чёлка: чуть медленнее обычного и с лёгкой упругостью, как Dynamic Island.
    @MainActor static var island: Animation { .spring(response: 0.62 * scale, dampingFraction: 0.8) }
    /// Закрытие чуть быстрее открытия: интерфейс не должен задерживать пользователя.
    @MainActor static var islandClose: Animation { .spring(response: 0.5 * scale, dampingFraction: 0.88) }
    /// Всплывающие панели.
    @MainActor static var panel: Animation { .spring(response: 0.36 * scale, dampingFraction: 0.86) }
    /// Мелкие реакции на наведение.
    @MainActor static var hover: Animation { .spring(response: 0.26 * scale, dampingFraction: 0.82) }
}
