import AppKit
import IOKit.hid
import QuartzCore
import SingluseCore

/// Перехватывает щелчки колеса мыши и заменяет их потоком маленьких пиксельных событий.
/// События трекпада идут мимо: у них уже есть родная инерция.
/// Всё работает на отдельном потоке, чтобы занятый интерфейс никогда не тормозил прокрутку.
final class SmoothScrollController: NSObject, @unchecked Sendable {
    /// Этой меткой мы подписываем свои события, чтобы не перехватить их повторно.
    private static let marker: Int64 = 0x534E_4755

    private let lock = NSLock()
    private var pendingSettings = ScrollSettings()
    private var excludedApps = Set<String>()
    private var frontmostApp: String?
    private var isActive = false
    private var calibrationSamples: [WheelSample]?

    // Эти поля трогает только поток прокрутки.
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var engine = ScrollEngine()
    private var displayLink: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    private let eventSource = CGEventSource(stateID: .combinedSessionState)
    private var activationObserver: NSObjectProtocol?

    override init() {
        super.init()
        frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.lock.withLock { self?.frontmostApp = app?.bundleIdentifier }
        }
    }

    func update(active: Bool, settings: ScrollSettings, excluded: [String]) {
        lock.lock()
        pendingSettings = settings
        excludedApps = Set(excluded)
        let changed = active != isActive
        isActive = active
        lock.unlock()
        guard changed else { return }
        active ? start() : stop()
    }

    // MARK: - Калибровка

    func beginCalibration() {
        lock.withLock { calibrationSamples = [] }
    }

    var calibrationCount: Int {
        lock.withLock { calibrationSamples?.count ?? 0 }
    }

    func endCalibration() -> [WheelSample] {
        lock.withLock {
            let samples = calibrationSamples ?? []
            calibrationSamples = nil
            return samples
        }
    }

    // MARK: - Поток и перехватчик

    private func start() {
        let thread = Thread { [weak self] in self?.threadMain() }
        thread.name = "Singluse.SmoothScroll"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func stop() {
        let loop = lock.withLock {
            let current = runLoop
            runLoop = nil
            return current
        }
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.shutdownOnThread()
            CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)
        thread = nil
    }

    private func threadMain() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<SmoothScrollController>.fromOpaque(refcon).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("Singluse: could not create scroll event tap (Accessibility missing?)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let loop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock { runLoop = loop }
        CFRunLoopRun()
    }

    private func shutdownOnThread() {
        displayLink?.invalidate()
        displayLink = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Система выключает медленные перехватчики; просто включаемся обратно.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
        else { return Unmanaged.passUnretained(event) }

        let dy = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let dx = Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        guard dy != 0 || dx != 0 else { return Unmanaged.passUnretained(event) }

        let (settings, excluded) = lock.withLock { () -> (ScrollSettings, Bool) in
            calibrationSamples?.append(WheelSample(time: CACurrentMediaTime(), delta: dy))
            return (pendingSettings, frontmostApp.map(excludedApps.contains) ?? false)
        }

        // ⌘/⌃ + колесо — это зум в приложениях, его нельзя растягивать. Исключённые приложения тоже не трогаем.
        guard !excluded, event.flags.isDisjoint(with: [.maskCommand, .maskControl]) else {
            return Unmanaged.passUnretained(event)
        }

        engine.settings = settings
        engine.addWheel(deltaY: dy, deltaX: dx, at: CACurrentMediaTime())
        startDisplayLinkIfNeeded()
        return nil
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        lastStep = CACurrentMediaTime()
        // Кадры идут строго в такт монитору (144 Гц, ProMotion и т. д.); в покое процессор не занят.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .current, forMode: .common)
        displayLink = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let (dy, dx) = engine.step(dt: now - lastStep)
        lastStep = now
        if dy != 0 || dx != 0 { post(dy: dy, dx: dx) }
        if engine.isIdle {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func post(dy: Int32, dx: Int32) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Без фаз жеста: с ними браузер принимал колесо за трекпад, оттягивал страницу у края
        // и при небольшом рывке вверх обновлял её (жест «потянуть, чтобы обновить»).
        // Shift + колесо должно остаться горизонтальной прокруткой.
        event.flags = CGEventSource.flagsState(.combinedSessionState)
        event.post(tap: .cgSessionEventTap)
    }
}

/// Подключённые внешние мыши. Для их перечисления разрешения не нужны.
struct MouseDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class MouseMonitor: ObservableObject {
    @Published private(set) var devices: [MouseDevice] = []
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    init() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_Mouse,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let changed: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<MouseMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.reload() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, changed, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, changed, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        reload()
    }

    private func reload() {
        let raw = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var found: [String: MouseDevice] = [:]
        for device in raw {
            let builtIn = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool ?? false
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
            guard !builtIn, let name, !name.isEmpty else { continue }
            let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
            let id = "\(vendor):\(product)"
            found[id] = MouseDevice(id: id, name: name)
        }
        let sorted = found.values.sorted { $0.name < $1.name }
        guard sorted != devices else { return }
        let added = sorted.first { !devices.contains($0) }
        devices = sorted
        // Подключили мышь с готовым профилем: её настройки включаются сами.
        if let added, let profile = AppSettings.shared.mouseProfiles[added.id] {
            AppSettings.shared.apply(profile)
        }
    }
}
