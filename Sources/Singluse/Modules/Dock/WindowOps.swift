import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import ScreenCaptureKit

/// Частный, но стабильный уже много лет вызов: связывает AX-окно с его системным номером.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// На каких рабочих столах находится окно. У скрытых служебных окон их нет, поэтому так отличают настоящее окно от заготовки.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: UInt32, _ mask: UInt32, _ windows: CFArray) -> CFArray?

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: UInt32) -> CFArray?

/// Действия с окнами другого приложения. Общие для превью в Dock и переключателя ⌥Tab.
@MainActor
enum WindowOps {
    /// Сначала ищем по номеру окна, затем по заголовку: не все приложения отдают номер.
    static func element(id: CGWindowID, pid: pid_t, title: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = AX.attribute(app, kAXWindowsAttribute) ?? []
        let byID = windows.first { element in
            var candidate: CGWindowID = 0
            return _AXUIElementGetWindow(element, &candidate) == .success && candidate == id
        }
        if let byID { return byID }
        return windows.first { AX.attribute($0, kAXTitleAttribute, as: String.self) == title }
    }

    /// Сразу выводит окно вперёд и делает его активным, чтобы не нужно было кликать ещё раз.
    /// Окно с другого рабочего стола или в полном экране система покажет, перейдя на его стол.
    static func focus(id: CGWindowID, pid: pid_t, title: String) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.unhide()
        if isOnHiddenSpaceOnly(id), WindowActivation.bringToFront(id: id, pid: pid) {
            // Пока идёт анимация перехода, окно ещё не видно приложению, поэтому поднимаем его уже на месте.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                MainActor.assumeIsolated {
                    guard let window = element(id: id, pid: pid, title: title) else { return }
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
            }
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        func raise() {
            // С macOS 14 приложение активируется, только если текущее уступает ему право на это.
            NSApp.yieldActivation(to: app)
            app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
            AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if let window = element(id: id, pid: pid, title: title) {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
        raise()
        // Приложение могло ещё не успеть стать активным; второй заход окончательно выводит нужное окно наверх.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            MainActor.assumeIsolated { raise() }
        }
    }

    /// Окно приложения для превью. Снимок есть не у всех: свёрнутые окна показываются значком.
    struct ListedWindow: @unchecked Sendable {
        let id: CGWindowID
        let title: String
        let isOnScreen: Bool
        let shareable: SCWindow?
    }

    /// Настоящее окно с другого рабочего стола: оно числится только на столах, которых сейчас не видно.
    /// Если окно числится на видимом столе, но не показывается, значит, приложение его скрыло.
    static func isOnHiddenSpaceOnly(_ id: CGWindowID) -> Bool {
        let connection = CGSMainConnectionID()
        let list = [NSNumber(value: id)] as CFArray
        guard let raw = CGSCopySpacesForWindows(connection, 7, list) as? [NSNumber], !raw.isEmpty else { return false }
        let displays = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] ?? []
        let visible = Set(displays.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber })
        return Set(raw).isDisjoint(with: visible)
    }

    /// Окно занимает экран целиком. У окон в полном экране бывает пустой заголовок, и это не повод считать их служебными.
    static func coversDisplay(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { abs($0.frame.width - frame.width) < 2 && abs($0.frame.height - frame.height) < 2 }
    }

    /// Окна, которые считает своими само приложение. Панели и служебные окна сюда не входят.
    struct AXWindows {
        var real: [CGWindowID: String] = [:]
        var order: [CGWindowID] = []
        var ignored = Set<CGWindowID>()
    }

    static func axWindows(pid: pid_t) -> AXWindows {
        var result = AXWindows()
        let root = AXUIElementCreateApplication(pid)
        let windows: [AXUIElement] = AX.attribute(root, kAXWindowsAttribute) ?? []
        for window in windows {
            var number: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &number) == .success, number != 0 else { continue }
            let subrole: String = AX.attribute(window, kAXSubroleAttribute) ?? ""
            if subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole || subrole.isEmpty {
                result.real[number] = AX.attribute(window, kAXTitleAttribute, as: String.self) ?? ""
                result.order.append(number)
            } else {
                result.ignored.insert(number)
            }
        }
        return result
    }

    /// Только настоящие окна приложения. Источник правды — само приложение (Accessibility): оно знает и свёрнутые окна.
    /// Окна с других рабочих столов оно не перечисляет, поэтому их берём из ScreenCaptureKit,
    /// но только если система действительно держит их на каком-то столе: скрытые заготовки вроде «Log In» там не числятся.
    static func windows(of app: NSRunningApplication) async -> [ListedWindow]? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return nil }
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier
        let ax = axWindows(pid: pid)
        let fallback = app.localizedName ?? ""
        let isOwnApp = pid == ProcessInfo.processInfo.processIdentifier

        var result: [ListedWindow] = []
        var seen = Set<CGWindowID>()
        let candidates = content.windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.processID == pid || (bundle != nil && owner.bundleIdentifier == bundle)
        }
        for window in candidates {
            let id = window.windowID
            guard window.windowLayer == 0, window.frame.width >= 100, window.frame.height >= 60, !ax.ignored.contains(id) else { continue }
            let title = window.title ?? ""
            let isReal: Bool
            if ax.real[id] != nil {
                isReal = true
            } else if isOwnApp {
                isReal = false
            } else if window.isOnScreen {
                // На виду, но приложение его не называет: верим только если оно вообще не отвечает на запросы.
                isReal = !title.isEmpty && ax.real.isEmpty && ax.ignored.isEmpty
            } else if title.isEmpty, !coversDisplay(window.frame) {
                isReal = false
            } else {
                isReal = isOnHiddenSpaceOnly(id)
            }
            guard isReal else { continue }
            let shown = title.isEmpty ? (ax.real[id] ?? "") : title
            result.append(ListedWindow(id: id, title: shown.isEmpty ? fallback : shown, isOnScreen: window.isOnScreen, shareable: window))
            seen.insert(id)
        }
        // Свёрнутых окон в списке захвата может не быть, но приложение о них знает.
        for number in ax.order where !seen.contains(number) {
            let title = ax.real[number] ?? ""
            result.append(ListedWindow(id: number, title: title.isEmpty ? fallback : title, isOnScreen: false, shareable: nil))
        }
        return result.sorted { ($0.isOnScreen ? 0 : 1) < ($1.isOnScreen ? 0 : 1) }
    }

    /// Последние снимки окон, общие для Dock и ⌥Tab: окно видно сразу, ещё до свежего снимка.
    static var thumbnails: [CGWindowID: NSImage] = [:]

    @discardableResult
    static func close(id: CGWindowID, pid: pid_t, title: String) -> Bool {
        guard let window = element(id: id, pid: pid, title: title),
              let button = AX.element(window, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func minimize(id: CGWindowID, pid: pid_t, title: String) -> Bool {
        guard let window = element(id: id, pid: pid, title: title) else { return false }
        if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success { return true }
        guard let button = AX.element(window, kAXMinimizeButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// То же, что зелёная кнопка окна. Повторное нажатие выводит из полного экрана.
    @discardableResult
    static func toggleFullScreen(id: CGWindowID, pid: pid_t, title: String) -> Bool {
        guard let window = element(id: id, pid: pid, title: title) else { return false }
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let attribute = "AXFullScreen" as CFString
        let isFull: Bool = AX.attribute(window, "AXFullScreen") ?? false
        if AXUIElementSetAttributeValue(window, attribute, (!isFull) as CFBoolean) == .success { return true }
        guard let button = AX.element(window, kAXFullScreenButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Обычное завершение, как ⌘Q: приложение само спросит про несохранённое.
    static func quit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    /// Снимок окна. Свёрнутые окна система снять не может, тогда вернётся nil.
    nonisolated static func capture(_ window: SCWindow, height: CGFloat, maxWidth: CGFloat) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let aspect = window.frame.width / max(window.frame.height, 1)
        // Двойной размер: миниатюра остаётся чёткой на Retina.
        configuration.width = Int(min(height * 2 * aspect, maxWidth * 2))
        configuration.height = Int(height * 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// Переход к окну на другом рабочем столе. Открытого способа нет: обычная активация приложения
/// выбирает стол сама и при окнах на нескольких столах часто приводит не туда. Это те же вызовы, что у AltTab.
/// Они ищутся при запуске: если будущая macOS их уберёт, сработает обычная активация.
enum WindowActivation {
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private static let processForPID: ProcessForPID? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: ProcessForPID.self) }

    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFront: SetFront? = dlsym(library, "_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFront.self) }
    private static let postEvent: PostEvent? = dlsym(library, "SLPSPostEventRecordTo").map { unsafeBitCast($0, to: PostEvent.self) }

    static var isAvailable: Bool { setFront != nil && postEvent != nil && processForPID != nil }

    static func bringToFront(id: CGWindowID, pid: pid_t) -> Bool {
        guard let setFront, let postEvent, let processForPID else { return false }
        var process = ProcessSerialNumber()
        guard processForPID(pid, &process) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFront(&process, id, userGenerated) == 0 else { return false }
        // Делает окно главным внутри приложения: иначе оно перейдёт на стол, но фокус останется на другом окне.
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x3A] = 0x10
        var number = id
        withUnsafeBytes(of: &number) { bytes in
            for offset in 0..<4 { record[0x3C + offset] = bytes[offset] }
        }
        for offset in 0..<0x10 { record[0x20 + offset] = 0xFF }
        record[0x08] = 0x01
        _ = postEvent(&process, &record)
        record[0x08] = 0x02
        _ = postEvent(&process, &record)
        return true
    }
}

/// Глобальные клавиши через Carbon: разрешений не требуют. Один обработчик на все сочетания.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let number = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeys.shared.actions[number]?() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    func register(id: UInt32, keyCode: Int, modifiers: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        unregister(id: id)
        actions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), modifiers, EventHotKeyID(signature: OSType(0x534E_4755), id: id), GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
    }

    func unregister(id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        actions[id] = nil
    }
}
