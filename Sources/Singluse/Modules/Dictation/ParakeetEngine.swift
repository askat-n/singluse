@preconcurrency import FluidAudio
import Foundation

/// Вторая модель Singluse: Parakeet от NVIDIA (через FluidAudio). Работает на этом Mac,
/// в разы быстрее Whisper и чаще точнее на русском. Расшифровывает каждую фразу вместе с Whisper,
/// а лучший вариант выбирается по согласию с независимым распознаванием Apple.
@MainActor
final class ParakeetEngine: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded

    /// Parakeet Ultra — дообученная версия Parakeet v3: те же 25 языков, меньше ошибок.
    static let version: AsrModelVersion = .ultra
    static let repository = "FluidInference/parakeet-ultra-coreml"
    private static let folderName = "parakeet-ultra-coreml"
    static let modelSizeTitle = L("примерно 630 МБ")
    /// Новую версию модели ищем раз в неделю.
    private static let updateInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Языки Parakeet v3. Для остальных работает только Whisper.
    static let languages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    private var manager: AsrManager?
    private var loadTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    /// Версия модели на Hugging Face (коммит), которая сейчас лежит на диске.
    private var installedRevision: String? {
        get { defaults.string(forKey: "parakeetRevision") }
        set { defaults.set(newValue, forKey: "parakeetRevision") }
    }

    private static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Singluse/Parakeet", isDirectory: true)
    }

    /// Каждая версия модели живёт в своей папке: новая скачивается рядом, пока старая работает.
    private static func modelDirectory(revision: String) -> URL {
        baseDirectory.appendingPathComponent(String(revision.prefix(12)), isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    var isDownloaded: Bool {
        guard let installedRevision else { return false }
        return AsrModels.modelsExist(at: Self.modelDirectory(revision: installedRevision), version: Self.version)
    }

    var isReady: Bool { state == .ready }

    static func supports(_ language: String) -> Bool {
        languages.contains(String(language.prefix(2)))
    }

    // MARK: - Загрузка

    /// Скачивает модель, если её ещё нет, и загружает в память. Повторный вызов ничего не делает.
    func prepare() {
        guard manager == nil, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            await self?.prepareNow()
            self?.loadTask = nil
            self?.checkForModelUpdateIfDue()
        }
    }

    func prepareNow() async {
        guard manager == nil else { return }
        do {
            let revision: String
            if isDownloaded, let installedRevision {
                revision = installedRevision
            } else {
                state = .downloading(0)
                revision = try await Self.latestRevision()
                try await download(revision: revision)
                removeOtherVersions(keeping: revision)
                installedRevision = revision
            }
            state = .loading
            manager = try await Self.load(revision: revision)
            state = .ready
        } catch {
            NSLog("Singluse: Parakeet preparation failed: \(error)")
            state = .failed(L("Не удалось подготовить модель"))
        }
    }

    private func download(revision: String) async throws {
        let directory = Self.modelDirectory(revision: revision)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await AsrModels.download(to: directory, version: Self.version) { [weak self] progress in
            let value = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(value)
                }
            }
        }
    }

    private static func load(revision: String) async throws -> AsrManager {
        let models = try await AsrModels.load(from: modelDirectory(revision: revision), version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return manager
    }

    /// Выгружает модель из памяти, когда она не нужна. Файлы остаются на диске.
    func unload() {
        if case .downloading = state { return }
        loadTask?.cancel()
        loadTask = nil
        manager = nil
        state = .notDownloaded
    }

    func deleteModel() {
        unload()
        updateTask?.cancel()
        updateTask = nil
        try? FileManager.default.removeItem(at: Self.baseDirectory)
        installedRevision = nil
        state = .notDownloaded
    }

    // MARK: - Распознавание

    /// Звук: 16 кГц, один канал. `language` — подсказка алфавита; при смеси языков её лучше не давать.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard let manager else { throw CancellationError() }
        // Модели нужна хотя бы секунда звука; короткую фразу дополняем тишиной.
        var audio = samples
        if audio.count < 16000 { audio += [Float](repeating: 0, count: 16000 - audio.count) }
        var decoderState = try TdtDecoderState()
        let hint = language.flatMap { Language(rawValue: String($0.prefix(2))) }
        let result = try await manager.transcribe(audio, decoderState: &decoderState, language: hint)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Обновление модели

    /// Раз в неделю смотрим, не вышла ли новая версия модели. Новая скачивается рядом со старой,
    /// и только когда она загружена и работает, старая удаляется — диктовка не прерывается ни на миг.
    func checkForModelUpdateIfDue() {
        guard isDownloaded, updateTask == nil else { return }
        let last = defaults.object(forKey: "parakeetUpdateCheck") as? Date
        if let last, Date().timeIntervalSince(last) < Self.updateInterval { return }
        updateTask = Task { [weak self] in
            await self?.updateModel()
            self?.updateTask = nil
        }
    }

    private func updateModel() async {
        guard let latest = try? await Self.latestRevision() else { return }
        defaults.set(Date(), forKey: "parakeetUpdateCheck")
        guard latest != installedRevision else { return }
        do {
            try await download(revision: latest)
            let fresh = try await Self.load(revision: latest)
            if manager != nil { manager = fresh }
            installedRevision = latest
            removeOtherVersions(keeping: latest)
            NSLog("Singluse: Parakeet updated to \(latest)")
        } catch {
            // Не вышло — остаёмся на рабочей версии, попробуем через неделю.
            try? FileManager.default.removeItem(at: Self.modelDirectory(revision: latest).deletingLastPathComponent())
            NSLog("Singluse: Parakeet update failed: \(error)")
        }
    }

    private func removeOtherVersions(keeping revision: String) {
        let keep = String(revision.prefix(12))
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.baseDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent != keep {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Последний коммит модели на Hugging Face.
    private static func latestRevision() async throws -> String {
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models/\(repository)")!)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String, sha.count >= 12 else { throw URLError(.badServerResponse) }
        return sha
    }
}
