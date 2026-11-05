import AppKit
import ApplicationServices
import IOKit.ps
import SwiftUI

/// Перевод строки, которая не попадает в SwiftUI как литерал. Ключ — русский текст.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Язык интерфейса. Названия языков на самих этих языках: человек должен найти свой, не зная текущего.
enum AppLanguage {
    static let all: [(code: String, name: String)] = [
        ("ru", "Русский"), ("en", "English"), ("es", "Español"), ("zh-Hans", "简体中文"),
        ("ar", "العربية"), ("fr", "Français"), ("vi", "Tiếng Việt"), ("ko", "한국어"), ("tl", "Tagalog"),
    ]

    private static let key = "AppleLanguages"

    /// Выбор пользователя; пустая строка — как в системе.
    static var current: String {
        guard let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String] else { return "" }
        return stored.first ?? ""
    }

    /// Язык, с которым приложение запущено: смена вступает в силу только после перезапуска.
    static let launched = current

    /// Арабский читается справа налево, и интерфейс должен зеркалиться вместе с ним.
    static var isRightToLeft: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ar") == true
    }

    static func set(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([code], forKey: key)
        }
    }
}

/// Панель, которая принимает клавиатуру, не забирая фокус у текущего приложения.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Первый клик по панели срабатывает сразу, а не только «активирует» её.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Батарея и питание: от них зависит пауза обоев и индикатор в чёлке.
@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var onBattery = false
    @Published private(set) var lowPowerMode = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if lowPower != lowPowerMode { lowPowerMode = lowPower }

        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  raw[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = raw[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(raw[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let level = current * 100 / maximum
            let charging = raw[kIOPSIsChargingKey] as? Bool ?? false
            let battery = (raw[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            if level != batteryLevel { batteryLevel = level }
            if charging != isCharging { isCharging = charging }
            if battery != onBattery { onBattery = battery }
            return
        }
    }
}

/// Вставка в активное приложение через синтетическое ⌘V.
enum Keystrokes {
    private static let keyV: CGKeyCode = 9

    static func pasteCommand() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Медиаклавиши работают с любым плеером, включая браузер.
    static func mediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let state = isDown ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int(key) << 16 | state << 8,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static let mediaPlayPause: Int32 = 16
    static let mediaNext: Int32 = 17
    static let mediaPrevious: Int32 = 18
}

/// Короткие обёртки над Accessibility API.
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String, as type: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

/// Перевод из координат Quartz/AX (начало вверху слева) в координаты AppKit (начало внизу слева).
func appKitRect(fromQuartz rect: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}
