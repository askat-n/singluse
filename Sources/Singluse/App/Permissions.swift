import AppKit
import ApplicationServices
import AVFoundation
import Speech

enum Permission: String, CaseIterable, Identifiable {
    case accessibility, screenRecording, microphone, speech

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return L("Универсальный доступ")
        case .screenRecording: return L("Запись экрана")
        case .microphone: return L("Микрофон")
        case .speech: return L("Распознавание речи")
        }
    }

    var reason: String {
        switch self {
        case .accessibility: return L("Прокрутка, горячие клавиши, вставка текста и управление окнами")
        case .screenRecording: return L("Миниатюры окон для превью в Dock")
        case .microphone: return L("Слышать голос, пока зажата клавиша")
        case .speech: return L("Превращать голос в текст")
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .microphone: return "mic.fill"
        case .speech: return "text.bubble.fill"
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .speech: anchor = "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// Следит за системными разрешениями. Сами запросы показываются только по нажатию кнопки.
@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var granted: Set<Permission> = []
    private var timer: Timer?

    init() {
        refresh()
        // Выдача доступа происходит в Системных настройках, уведомления об этом нет.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func has(_ permission: Permission) -> Bool { granted.contains(permission) }
    func hasAll(_ list: [Permission]) -> Bool { list.allSatisfy(has) }
    func missing(for module: Module) -> [Permission] { module.requiredPermissions.filter { !has($0) } }

    func refresh() {
        var current = Set<Permission>()
        if AXIsProcessTrusted() { current.insert(.accessibility) }
        if CGPreflightScreenCaptureAccess() { current.insert(.screenRecording) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { current.insert(.microphone) }
        if SFSpeechRecognizer.authorizationStatus() == .authorized { current.insert(.speech) }
        if current != granted { granted = current }
    }

    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
                NSWorkspace.shared.open(permission.settingsURL)
            }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() {
                NSWorkspace.shared.open(permission.settingsURL)
            }
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in
                    DispatchQueue.main.async { Coordinator.shared.permissions.refresh() }
                }
            default:
                NSWorkspace.shared.open(permission.settingsURL)
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { @Sendable _ in
                    DispatchQueue.main.async { Coordinator.shared.permissions.refresh() }
                }
            default:
                NSWorkspace.shared.open(permission.settingsURL)
            }
        }
    }

    /// Запись экрана система применяет только после перезапуска приложения.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
