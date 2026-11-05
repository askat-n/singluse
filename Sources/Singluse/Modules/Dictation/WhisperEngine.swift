import Foundation
import WhisperKit

/// Модель Singluse: Whisper на этом Mac. Голос никуда не отправляется, а работа не стоит денег.
/// Модель скачивается один раз и живёт в папке приложения.
@MainActor
final class WhisperEngine: ObservableObject {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notDownloaded

    static let modelName = "openai_whisper-large-v3-v20240930_626MB"
    static let modelSizeTitle = L("примерно 630 МБ")

    private var pipe: WhisperKit?
    private var loadTask: Task<Void, Never>?
    /// Запросы идут строго по одному, и у каждого своя задача. Поэтому отмена вызывающего кода
    /// (клавишу отпустили посреди разбора) не обрывает работу и не теряет уже сказанное.
    private var lastJob: Task<Void, Never>?

    private static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Singluse/Whisper", isDirectory: true)
    }

    /// Папка модели внутри `downloadBase` повторяет путь на Hugging Face.
    private static var modelDirectory: URL {
        baseDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelName)", isDirectory: true)
    }

    var isDownloaded: Bool {
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: Self.modelDirectory.appendingPathComponent($0).path)
        }
    }

    var isReady: Bool { state == .ready }

    /// Скачивает модель, если её ещё нет, и загружает в память. Повторный вызов ничего не делает.
    func prepare() {
        guard pipe == nil, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            await self?.prepareNow()
            self?.loadTask = nil
        }
    }

    func prepareNow() async {
        guard pipe == nil else { return }
        do {
            if !isDownloaded {
                state = .downloading(0)
                try FileManager.default.createDirectory(at: Self.baseDirectory, withIntermediateDirectories: true)
                _ = try await WhisperKit.download(
                    variant: Self.modelName,
                    downloadBase: Self.baseDirectory,
                    progressCallback: { [weak self] progress in
                        let value = progress.fractionCompleted
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.state = .downloading(value) }
                        }
                    }
                )
            }
            state = .loading
            let config = WhisperKitConfig(
                model: Self.modelName,
                downloadBase: Self.baseDirectory,
                modelFolder: Self.modelDirectory.path,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true,
                download: false
            )
            pipe = try await WhisperKit(config)
            state = .ready
        } catch {
            NSLog("Singluse: Whisper preparation failed: \(error)")
            state = .failed("Не удалось подготовить модель")
        }
    }

    /// Выгружает модель из памяти, когда движок не выбран. Файлы остаются на диске.
    func unload() {
        if case .downloading = state { return }
        loadTask?.cancel()
        loadTask = nil
        pipe = nil
        state = .notDownloaded
    }

    func deleteModel() {
        unload()
        try? FileManager.default.removeItem(at: Self.modelDirectory)
        state = .notDownloaded
    }

    /// Звук: 16 кГц, один канал.
    /// - `second`: второй язык речи (например, английские слова внутри русской фразы).
    /// - `context`: уже распознанный текст, чтобы следующая часть продолжала его по смыслу.
    /// - `heardByApple`: услышал ли слова второй, независимый движок; без него сомнительный текст отбрасывается.
    func transcribe(
        samples: [Float],
        language: String,
        second: String? = nil,
        hints: [String] = [],
        context: String = "",
        heardByApple: Bool = false,
        isMeeting: Bool = false,
        plainPrompt: Bool = false
    ) async throws -> String {
        let previous = lastJob
        let job = Task { @MainActor [self] in
            await previous?.value
            return try await run(samples: samples, language: language, second: second, hints: hints, context: context, heardByApple: heardByApple, isMeeting: isMeeting, plainPrompt: plainPrompt)
        }
        lastJob = Task { _ = try? await job.value }
        return try await job.value
    }

    private func run(
        samples: [Float],
        language: String,
        second: String?,
        hints: [String],
        context: String,
        heardByApple: Bool,
        isMeeting: Bool,
        plainPrompt: Bool
    ) async throws -> String {
        guard let pipe else { throw AIError(message: L("Модель ещё не готова")) }
        // На тишине Whisper склонен выдумывать текст, поэтому беззвучную запись даже не отправляем.
        // Если движок Apple уже услышал слова, это точно речь, пусть и тихая: её выбрасывать нельзя.
        guard heardByApple || Self.hasSpeechLevel(samples) else { return "" }

        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 1,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            windowClipTime: 0,
            chunkingStrategy: .vad
        )
        // Подсказка задаёт манеру: модель продолжает её, поэтому ставит знаки и не переводит слова.
        let prompt = Self.promptText(language: language, second: second, hints: hints, context: context)
        if !plainPrompt, let tokenizer = pipe.tokenizer {
            let begin = tokenizer.specialTokens.specialTokenBegin
            options.promptTokens = tokenizer.encode(text: " " + prompt).filter { $0 < begin }
        }
        // Немного тишины в конце: библиотека не разбирает самый край записи, и последнее слово могло бы пропасть.
        let padded = Self.normalized(samples) + [Float](repeating: 0, count: 8000)
        let results = try await pipe.transcribe(audioArray: padded, decodeOptions: options)

        // Модель сама сообщает, насколько уверена. Сомнительные куски — это обычно шум, а не речь.
        let segments = results.flatMap(\.segments)
        // Если речь подтверждена вторым движком, неуверенный кусок всё равно лучше дыры в тексте.
        let text = segments
            .filter { heardByApple || $0.avgLogprob > Self.minLogProbability }
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Если модель просто повторила подсказку, значит, слов в записи не было.
        // Хвост уже сказанного в подсказке не считается: человек вполне может повторить свои слова.
        if text.isEmpty || (!heardByApple && context.isEmpty && prompt.contains(text)) { return "" }
        // Если речь подтвердил движок Apple, «Спасибо» — это настоящее слово, а не галлюцинация.
        if !heardByApple, Self.isKnownHallucination(text) { return "" }
        // В встрече второго движка нет, а живая речь через динамики и по сети редко звучит чисто,
        // поэтому порог там мягче: запись уже прошла проверку на речь выше.
        let threshold = isMeeting ? Self.meetingLogProbability : Self.doubtfulLogProbability
        let confident = segments.contains { $0.avgLogprob > threshold }
        return confident || heardByApple ? text : ""
    }

    private static let minLogProbability: Float = -1.0
    /// Ниже этой уверенности текст верится только вместе с движком Apple: так чаще всего выглядит шум.
    private static let doubtfulLogProbability: Float = -0.15
    private static let meetingLogProbability: Float = -0.7

    /// Whisper учился на субтитрах и на паузах иногда дописывает их служебные фразы.
    nonisolated static func isKnownHallucination(_ text: String) -> Bool {
        let cleaned = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let phrases = [
            "продолжение следует", "субтитры", "субтитры сделал", "субтитры создавал", "спасибо за просмотр",
            "спасибо", "спасибо за внимание", "до новых встреч", "подписывайтесь на канал", "редактор субтитров",
            "thank you", "thanks for watching", "subtitles by", "please subscribe", "you",
        ]
        return phrases.contains(cleaned) || cleaned.hasPrefix("субтитры")
    }

    /// Выравнивает громкость. Модель плохо слышит тихий звук и начинает выдумывать слова,
    /// а тихая речь или далёкий микрофон — обычное дело. Усиление ограничено, чтобы не раздувать шум.
    nonisolated static func normalized(_ samples: [Float]) -> [Float] {
        let window = 320
        guard samples.count >= window else { return samples }
        var energies: [Float] = []
        var index = 0
        while index + window <= samples.count {
            let slice = samples[index..<index + window]
            energies.append(slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(window))
            index += window
        }
        energies.sort()
        let loud = energies[energies.count * 95 / 100].squareRoot()
        guard loud > 0.0002 else { return samples }
        let gain = min(max(0.12 / loud, 1), 60)
        guard gain > 1.05 else { return samples }
        return samples.map { min(max($0 * gain, -1), 1) }
    }

    /// Похоже ли это на речь. Голос — это слоги и паузы, поэтому громкость всё время скачет;
    /// у ровного шума вентилятора или шипения микрофона она почти постоянна.
    nonisolated static func hasSpeechLevel(_ samples: [Float]) -> Bool {
        let window = 320 // 20 мс
        guard samples.count >= window * 5 else { return false }
        var energies: [Float] = []
        var index = 0
        while index + window <= samples.count {
            let slice = samples[index..<index + window]
            energies.append(slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(window))
            index += window
        }
        energies.sort()
        let quiet = energies[energies.count / 10]
        let loud = energies[energies.count * 95 / 100]
        guard loud.squareRoot() > 0.001 else { return false }
        return loud / max(quiet, 1e-9) > 6
    }

    private static func promptText(language: String, second: String?, hints: [String], context: String) -> String {
        var style: String
        switch (language, second) {
        case ("ru", "en"?): style = "Открой pull request в GitHub. Let's go, ok?"
        case ("en", "ru"?): style = "Hello! Давай созвонимся завтра, ok?"
        case ("ru", _): style = "Привет! Как дела?"
        default: style = "Hello! How are you?"
        }
        if !hints.isEmpty { style += " " + hints.joined(separator: ", ") + "." }
        // Хвост уже сказанного важнее примера стиля: он даёт и манеру, и тему.
        let tail = String(context.suffix(80))
        return tail.isEmpty ? style : style + " " + tail
    }
}
