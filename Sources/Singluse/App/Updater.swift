import AppKit
import Security
import SingluseCore
import SwiftUI

/// Обновления из релизов на GitHub: раз в день смотрим последний релиз и, если он новее,
/// предлагаем установить его, как это делают обычные приложения для Mac.
@MainActor
final class Updater: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case available(ReleaseInfo)
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let repository = "askat-n/singluse"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "updateLastCheck") as? Date

    private var timer: Timer?
    private var window: NSWindow?
    private var download: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    static var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion("0")!
    }

    func start() {
        // Первая проверка — вскоре после запуска, когда всё остальное уже поднялось; дальше раз в час смотрим, не прошли ли сутки.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 300
    }

    private func checkIfDue() {
        guard AppSettings.shared.autoCheckUpdates else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        Task { await check(manual: false) }
    }

    /// `manual` — человек сам нажал «Проверить»: тогда сообщаем и о том, что обновлений нет, и об ошибке.
    func check(manual: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Singluse/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let release = ReleaseInfo.parse(data) else {
                throw UpdateError.badResponse
            }
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "updateLastCheck")
            let skipped = AppSettings.shared.skippedUpdateVersion
            if release.version > Self.currentVersion, manual || skipped != release.version.description {
                state = .available(release)
                showWindow()
            } else {
                state = .idle
                if manual { showUpToDate() }
            }
        } catch {
            state = manual ? .failed(L("Не удалось проверить обновления. Проверьте подключение к интернету.")) : .idle
            if manual { showWindow() }
        }
    }

    // MARK: - Окно

    func showWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = L("Обновление Singluse")
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: UpdateView(updater: self))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        window?.close()
        if case .available = state { state = .idle }
        if case .failed = state { state = .idle }
    }

    func skip(_ release: ReleaseInfo) {
        AppSettings.shared.skippedUpdateVersion = release.version.description
        closeWindow()
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = L("У вас последняя версия")
        alert.informativeText = String(format: L("Singluse %@ — самая новая версия."), Self.currentVersion.description)
        alert.icon = NSApp.applicationIconImage
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Установка

    func install(_ release: ReleaseInfo) {
        guard let url = release.downloadURL else {
            NSWorkspace.shared.open(release.pageURL)
            closeWindow()
            return
        }
        // Приложение, запущенное прямо из «Загрузок», macOS держит в защищённой временной копии — заменить его нельзя.
        let bundle = Bundle.main.bundleURL
        guard !bundle.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            state = .failed(L("Не получается заменить приложение на месте. Перенесите Singluse в папку «Программы» и попробуйте снова, или скачайте новую версию со страницы релиза."))
            return
        }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] file, response, error in
            // Временный файл исчезает сразу после выхода из этого обработчика, поэтому переносим его здесь.
            var kept: URL?
            if let file, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("Singluse-update-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: file, to: target)) != nil { kept = target }
            }
            let cancelled = (error as? URLError)?.code == .cancelled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progressObservation = nil
                    self.download = nil
                    if cancelled { return }
                    if let kept { self.unpackAndInstall(kept, release: release) } else {
                        self.state = .failed(L("Не удалось скачать обновление. Проверьте подключение к интернету."))
                    }
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(value)
                }
            }
        }
        download = task
        task.resume()
    }

    func cancelDownload() {
        download?.cancel()
        download = nil
        progressObservation = nil
        closeWindow()
        state = .idle
    }

    private func unpackAndInstall(_ archive: URL, release: ReleaseInfo) {
        state = .installing
        let current = Bundle.main.bundleURL
        Task.detached {
            let result = Self.prepare(archive: archive, replacing: current, expected: release.version)
            await MainActor.run {
                switch result {
                case .success(let newApp): self.relaunch(into: newApp, replacing: current)
                case .failure(let error): self.state = .failed(error.message)
                }
            }
        }
    }

    /// Распаковывает архив и проверяет, что внутри именно Singluse нужной версии, подписанный тем же разработчиком.
    nonisolated private static func prepare(archive: URL, replacing current: URL, expected: AppVersion) -> Result<URL, UpdateError> {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Singluse-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: archive) }
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return .failure(.unpack) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        do { try ditto.run() } catch { return .failure(.unpack) }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let app = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app)
        else { return .failure(.unpack) }

        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init),
              version == expected
        else { return .failure(.wrongApp) }
        guard let newTeam = teamIdentifier(of: app), newTeam == teamIdentifier(of: current) else { return .failure(.signature) }
        return .success(app)
    }

    /// Команда разработчика из подписи. Обновление ставится, только если она совпадает с текущим приложением:
    /// так подменённый архив не сможет выдать себя за Singluse, а выданные разрешения сохранятся.
    nonisolated private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Заменить запущенное приложение изнутри нельзя, поэтому это делает маленький скрипт после нашего выхода.
    private func relaunch(into newApp: URL, replacing current: URL) {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.old"
        if mv "$3" "$3.old" && mv "$2" "$3"; then
            rm -rf "$3.old"
        elif [ -d "$3.old" ] && [ ! -d "$3" ]; then
            mv "$3.old" "$3"
        fi
        xattr -dr com.apple.quarantine "$3" 2>/dev/null
        open "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "singluse-update", String(ProcessInfo.processInfo.processIdentifier), newApp.path, current.path]
        do {
            try process.run()
        } catch {
            state = .failed(UpdateError.unpack.message)
            return
        }
        Coordinator.shared.clipboard.saveNow()
        NSApp.terminate(nil)
    }
}

enum UpdateError: Error {
    case badResponse, unpack, wrongApp, signature

    var message: String {
        switch self {
        case .badResponse: return L("Не удалось проверить обновления. Проверьте подключение к интернету.")
        case .unpack: return L("Не удалось установить обновление. Скачайте новую версию со страницы релиза.")
        case .wrongApp, .signature: return L("Скачанный файл не прошёл проверку подписи, поэтому он не установлен.")
        }
    }
}

// MARK: - Интерфейс

private struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(24)
        .padding(.top, 8)
        .frame(width: 520, height: 380, alignment: .topLeading)
    }

    private var title: String {
        switch updater.state {
        case .available: return L("Доступна новая версия Singluse")
        case .downloading: return L("Загрузка обновления…")
        case .installing: return L("Установка…")
        case .failed: return L("Обновление не удалось")
        case .idle, .checking: return L("Проверка обновлений…")
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .available(let release):
            return String(format: L("Версия %@ готова к установке. У вас %@."), release.version.description, Updater.currentVersion.description)
        case .downloading, .installing:
            return L("Singluse перезапустится сам, когда всё будет готово.")
        case .failed(let message):
            return message
        case .idle, .checking:
            return ""
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .available(let release):
            ScrollView {
                Text(notes(release.notes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            HStack {
                Button("Пропустить эту версию") { updater.skip(release) }
                Spacer()
                Button("Позже") { updater.closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Установить") { updater.install(release) }
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let progress):
            Spacer()
            ProgressView(value: progress)
            HStack {
                Spacer()
                Button("Отменить") { updater.cancelDownload() }
            }
        case .installing, .checking, .idle:
            Spacer()
            ProgressView().progressViewStyle(.linear)
        case .failed:
            Spacer()
            HStack {
                Button("Открыть страницу релиза") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repository)/releases/latest")!)
                }
                Spacer()
                Button("Закрыть") { updater.closeWindow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Описание релиза написано в Markdown; показываем его с оформлением, а не со звёздочками.
    private func notes(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
