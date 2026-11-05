import AppKit
import AVFoundation
import Combine
import CoreMedia
import ScreenCaptureKit
import SingluseCore

struct MeetingLine: Codable, Identifiable, Equatable {
    var id = UUID()
    var seconds: Double
    /// true — говорил владелец компьютера (микрофон), false — собеседники (звук компьютера).
    var isMe: Bool
    var text: String
}

struct Meeting: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
    var duration: Double = 0
    var lines: [MeetingLine] = []
    /// Номер заметки в приложении «Заметки», чтобы дополнять её, а не плодить новые.
    var noteID: String?

    var plainText: String {
        lines.map { "[\(Self.time($0.seconds))] \($0.isMe ? L("Я") : L("Собеседники")): \($0.text)" }.joined(separator: "\n")
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Запись в «Заметки». Система один раз спросит разрешение на управление ими.
enum NotesBridge {
    static let folderName = "Singluse meetings"
    private static let queue = DispatchQueue(label: "Singluse.Notes")
    /// Заметки встреч, созданные в этом запуске. Сохранения идут очередью: второе должно увидеть результат первого,
    /// иначе пока система спрашивает разрешение, одна встреча превратилась бы в несколько заметок.
    nonisolated(unsafe) private static var createdNotes: [UUID: String] = [:]

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func html(_ meeting: Meeting) -> String {
        var body = "<h1>\(escapeHTML(meeting.title))</h1>"
        for line in meeting.lines {
            let who = line.isMe ? L("Я") : L("Собеседники")
            body += "<div><b>\(Meeting.time(line.seconds)) \(escapeHTML(who)):</b> \(escapeHTML(line.text))</div>"
        }
        return body
    }

    /// Создаёт папку при необходимости, создаёт или обновляет заметку. Возвращает её номер.
    static func save(_ meeting: Meeting, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        let body = html(meeting), title = meeting.title, knownID = meeting.noteID, meetingID = meeting.id
        queue.async {
            let source: String
            if let noteID = knownID ?? createdNotes[meetingID] {
                source = """
                tell application id "com.apple.Notes"
                    set body of note id \(quoted(noteID)) to \(quoted(body))
                    return \(quoted(noteID))
                end tell
                """
            } else {
                source = """
                tell application id "com.apple.Notes"
                    if not (exists folder \(quoted(folderName))) then
                        make new folder with properties {name:\(quoted(folderName))}
                    end if
                    set theNote to make new note at folder \(quoted(folderName)) with properties {name:\(quoted(title)), body:\(quoted(body))}
                    return id of theNote
                end tell
                """
            }
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let id = result?.stringValue {
                createdNotes[meetingID] = id
                completion(.success(id))
            } else {
                let message = error?[NSAppleScript.errorMessage] as? String ?? "Notes"
                completion(.failure(AIError(message: message)))
            }
        }
    }

    static func show(noteID: String) {
        queue.async {
            let source = """
            tell application id "com.apple.Notes"
                activate
                show note id \(quoted(noteID))
            end tell
            """
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}

/// Накопитель звука 16 кГц для одной дорожки. Пишут в него аудиопотоки, читает цикл распознавания.
private final class TrackBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var consumedSeconds: Double = 0

    func append(_ new: [Float]) {
        lock.withLock { samples.append(contentsOf: new) }
    }

    func snapshot() -> [Float] {
        lock.withLock { samples }
    }

    func consume(_ count: Int) {
        lock.withLock {
            samples.removeFirst(min(count, samples.count))
            consumedSeconds += Double(count) / 16000
        }
    }
}

/// Звук компьютера (голоса собеседников в Zoom, Meet и т. д.) через ScreenCaptureKit.
private final class SystemAudioTap: NSObject, SCStreamOutput, @unchecked Sendable {
    private let buffer: TrackBuffer
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Singluse.SystemAudio")

    init(buffer: TrackBuffer) {
        self.buffer = buffer
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AIError(message: L("Экран не найден")) }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 16000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        // Видео не нужно, но поток обязан его иметь: берём минимум, чтобы не нагружать систему.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let block = sampleBuffer.dataBuffer else { return }
        let bytes = CMBlockBufferGetDataLength(block)
        var floats = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
        floats.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: base)
            }
        }
        buffer.append(floats)
    }
}

/// Запись встречи: микрофон и звук компьютера разбираются по отдельности, поэтому видно, кто говорил.
/// Текст сохраняется по ходу записи, так что сбой не уносит всю встречу.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var current: Meeting?
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var startDate: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notesStatus: String?

    private var engine: AVAudioEngine?
    private let micTrack = TrackBuffer()
    private let systemTrack = TrackBuffer()
    private var systemTap: SystemAudioTap?
    private var loopTask: Task<Void, Never>?
    private var lastNotesSync = Date()
    private var notesDirty = false

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Singluse/Meetings", isDirectory: true)
    }

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        meetings = files.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Meeting.self, from: $0) }
        }.sorted { $0.date > $1.date }
    }

    private func save(_ meeting: Meeting) {
        guard let data = try? JSONEncoder().encode(meeting) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appendingPathComponent("\(meeting.id.uuidString).json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func delete(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(meeting.id.uuidString).json"))
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    // MARK: - Запуск

    func start() {
        guard !isRecording, !isFinishing else { return }
        errorMessage = nil
        notesStatus = nil
        let whisper = Coordinator.shared.whisper
        let settings = AppSettings.shared
        guard settings.dictationEngine == "whisper", whisper.isReady else {
            errorMessage = L("Для записи встреч нужна готовая модель Singluse: выберите её в разделе «Голосовой ввод».")
            return
        }
        guard Coordinator.shared.permissions.has(.microphone) else {
            errorMessage = L("Нужно разрешение на микрофон.")
            return
        }
        do {
            try startMicrophone()
        } catch {
            errorMessage = L("Не удалось включить микрофон")
            return
        }

        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        let meeting = Meeting(title: L("Встреча") + " " + formatter.string(from: date), date: date)
        current = meeting
        startDate = date
        isRecording = true
        lastNotesSync = date
        save(meeting)
        syncNotes()

        // Без разрешения на запись экрана собеседников не слышно, но свой голос всё равно пишется.
        let tap = SystemAudioTap(buffer: systemTrack)
        systemTap = tap
        Task { [weak self] in
            do {
                try await tap.start()
            } catch {
                NSLog("Singluse: system audio failed: \(error)")
                self?.errorMessage = L("Голоса собеседников не записываются: нужно разрешение «Запись экрана».")
            }
        }
        loopTask = Task { [weak self] in await self?.recognitionLoop() }
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let settings = AppSettings.shared
        if !settings.dictationMic.isEmpty, let device = AudioInput.deviceID(uid: settings.dictationMic), let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        // Подавление эха: иначе микрофон слышит собеседников из динамиков, и их слова попадут в запись дважды.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw AIError(message: "format")
        }
        let track = micTrack
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / format.sampleRate + 256)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
            track.append(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    // MARK: - Распознавание

    private func recognitionLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard isRecording else { return }
            await processTrack(micTrack, isMe: true, flush: false)
            await processTrack(systemTrack, isMe: false, flush: false)
            current?.duration = Date().timeIntervalSince(startDate ?? Date())
            if let current { save(current) }
            // В «Заметки» пишем реже: это медленный вызов другого приложения.
            if notesDirty, Date().timeIntervalSince(lastNotesSync) > 30 {
                syncNotes()
            }
        }
    }

    private func processTrack(_ track: TrackBuffer, isMe: Bool, flush: Bool) async {
        let samples = track.snapshot()
        guard !samples.isEmpty else { return }
        guard let cut = flush ? samples.count : SpeechChunker.cutPoint(in: samples, minimumSeconds: 4, maximumSeconds: 25) else { return }
        let start = track.consumedSeconds
        let chunk = Array(samples[..<cut])
        track.consume(cut)

        let settings = AppSettings.shared
        let language = Locale(identifier: settings.dictationLocale).language.languageCode?.identifier ?? "ru"
        let second = settings.dictationSecondLanguage.isEmpty ? nil : settings.dictationSecondLanguage
        let context = current?.lines.last?.text ?? ""
        guard let text = try? await Coordinator.shared.whisper.transcribe(samples: chunk, language: language, second: second, hints: settings.vocabularyTerms, context: context, isMeeting: true),
              !text.isEmpty else { return }
        current?.lines.append(MeetingLine(seconds: start, isMe: isMe, text: text))
        current?.lines.sort { $0.seconds < $1.seconds }
        notesDirty = true
    }

    private func syncNotes() {
        guard let meeting = current else { return }
        lastNotesSync = Date()
        notesDirty = false
        NotesBridge.save(meeting) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyNotesResult(result, meetingID: meeting.id) }
            }
        }
    }

    private func applyNotesResult(_ result: Result<String, Error>, meetingID: UUID) {
        switch result {
        case .success(let id):
            notesStatus = nil
            if current?.id == meetingID {
                current?.noteID = id
                if let current { save(current) }
            } else if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
                meetings[index].noteID = id
                save(meetings[index])
            }
        case .failure(let error):
            NSLog("Singluse: Notes failed: \(error.localizedDescription)")
            notesStatus = L("В «Заметки» сохранить не удалось: проверьте разрешение в Системных настройках. В Singluse запись сохранена.")
        }
    }

    // MARK: - Остановка

    func stop() {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        loopTask?.cancel()
        loopTask = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let tap = systemTap
        systemTap = nil
        Task { [weak self] in
            await tap?.stop()
            await self?.finish()
        }
    }

    private func finish() async {
        await processTrack(micTrack, isMe: true, flush: true)
        await processTrack(systemTrack, isMe: false, flush: true)
        guard var meeting = current else {
            isFinishing = false
            return
        }
        meeting.duration = Date().timeIntervalSince(startDate ?? Date())
        current = nil
        startDate = nil
        isFinishing = false
        meetings.insert(meeting, at: 0)
        save(meeting)
        NotesBridge.save(meeting) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyNotesResult(result, meetingID: meeting.id) }
            }
        }
    }
}
