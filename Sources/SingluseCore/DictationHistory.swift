import Foundation

/// Одна диктовка: что сказано, где и попало ли это в поле ввода.
public struct DictationEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var date: Date
    public var appName: String?
    /// false — поля ввода не было, текст остался только в буфере.
    public var wasInserted: Bool

    public init(id: UUID = UUID(), text: String, date: Date = Date(), appName: String? = nil, wasInserted: Bool = true) {
        self.id = id
        self.text = text
        self.date = date
        self.appName = appName
        self.wasInserted = wasInserted
    }
}

public struct DictationHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [DictationEntry]
    public var limit: Int

    public init(entries: [DictationEntry] = [], limit: Int = 1000) {
        self.entries = entries
        self.limit = limit
    }

    public mutating func add(_ entry: DictationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    public func search(_ query: String) -> [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(q) || ($0.appName ?? "").localizedCaseInsensitiveContains(q)
        }
    }
}

/// Как текст должен выглядеть в конкретном приложении.
public enum WritingStyle: String, Codable, CaseIterable, Sendable {
    /// Как сказано, с обычной пунктуацией.
    case standard
    /// Почта и документы.
    case business
    /// Мессенджеры: без точки в конце, как люди пишут в чатах.
    case casual

    /// То, что можно сделать без ИИ. Настоящую смену тона даёт редактура ИИ.
    public func applyLocally(to text: String) -> String {
        guard self == .casual else { return text }
        var result = text
        // Точку в конце убираем только у одного предложения: в длинном тексте она нужна.
        let sentenceEnds = result.filter { ".!?…".contains($0) }.count
        if result.hasSuffix("."), !result.hasSuffix("..."), sentenceEnds == 1 {
            result.removeLast()
        }
        return result
    }
}

/// Пауза в речи: удобное место, чтобы разрезать запись и распознавать её по частям, пока человек говорит.
public enum SpeechChunker {
    /// Закончил ли человек говорить: в конце записи идёт тишина заметно тише самой речи.
    public static func endsWithPause(_ samples: [Float], pauseSeconds: Double = 0.22) -> Bool {
        let window = 320
        let tail = Int(pauseSeconds * 16000)
        guard samples.count > tail + window * 10 else { return false }
        let speechPart = samples[..<(samples.count - tail)]
        let tailPart = samples[(samples.count - tail)...]
        func level(_ slice: ArraySlice<Float>) -> Float {
            (slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(slice.count, 1))).squareRoot()
        }
        var loud: Float = 0
        var index = speechPart.startIndex
        while index + window <= speechPart.endIndex {
            loud = max(loud, level(speechPart[index..<index + window]))
            index += window
        }
        return loud > 0.0005 && level(tailPart) < loud * 0.12
    }

    /// Появилась ли новая речь после заданного места.
    public static func hasSpeech(in samples: ArraySlice<Float>, comparedTo reference: [Float]) -> Bool {
        guard !samples.isEmpty, !reference.isEmpty else { return false }
        let peak = reference.reduce(Float(0)) { max($0, abs($1)) }
        let threshold = peak * 0.05
        return samples.contains { abs($0) > threshold }
    }

    /// Возвращает индекс конца части или nil, если резать пока рано.
    /// `samples` — звук 16 кГц, начиная с ещё не распознанного места.
    /// Тишина определяется относительно самой речи: микрофон бывает тихим,
    /// и абсолютный порог принял бы всю фразу за паузу и разрезал её посреди слова.
    public static func cutPoint(
        in samples: [Float],
        minimumSeconds: Double = 8,
        maximumSeconds: Double = 18,
        pauseSeconds: Double = 0.3
    ) -> Int? {
        let rate = 16000.0
        guard Double(samples.count) >= minimumSeconds * rate else { return nil }
        let window = 320
        var levels: [Float] = []
        var position = 0
        while position + window <= samples.count {
            let slice = samples[position..<position + window]
            levels.append((slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(window)).squareRoot())
            position += window
        }
        let sorted = levels.sorted()
        let loud = sorted[sorted.count * 95 / 100]
        let quiet = sorted[sorted.count / 100]
        // Настоящая пауза намного тише речи. Если разницы почти нет, это ровный шум или сплошная речь.
        let hasContrast = loud > quiet * 4 && loud > 0.0005
        if hasContrast {
            let threshold = quiet + (loud - quiet) * 0.12
            let pauseWindows = Int(pauseSeconds * rate) / window
            let firstAllowed = Int(minimumSeconds * rate * 0.6) / window
            var quietRun = 0
            var best: Int?
            for index in firstAllowed..<levels.count {
                quietRun = levels[index] < threshold ? quietRun + 1 : 0
                if quietRun >= pauseWindows {
                    // Режем посередине паузы, чтобы не задеть слова с обеих сторон.
                    best = (index + 1 - quietRun / 2) * window
                }
            }
            if let best { return best }
        }
        // Человек говорит без пауз слишком долго: режем принудительно, иначе ответа придётся ждать.
        if Double(samples.count) >= maximumSeconds * rate { return samples.count }
        return nil
    }
}

/// Сверка двух распознаваний одной записи. Whisper точнее, но иногда замолкает раньше времени;
/// движок Apple грубее, зато идёт по всей записи. Его слова показывают, не потерялось ли что-нибудь.
public enum TranscriptGuard {
    private static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    public static func wordCount(_ text: String) -> Int { words(text).count }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().replacingOccurrences(of: "ё", with: "е")
        let y = b.lowercased().replacingOccurrences(of: "ё", with: "е")
        if x == y { return true }
        return x.count >= 4 && y.count >= 4 && x.prefix(4) == y.prefix(4)
    }

    /// Точный текст намного короче черновика: пропал кусок.
    public static func looksCut(exact: String, draft: String) -> Bool {
        let heard = wordCount(draft)
        return heard >= 6 && Double(wordCount(exact)) < Double(heard) * 0.6
    }

    /// Насколько два текста совпадают по словам: длина общей подпоследовательности к длине большего, от 0 до 1.
    public static func agreement(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var diagonal = 0
            for j in 1...y.count {
                let above = row[j]
                row[j] = same(x[i - 1], y[j - 1]) ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return Double(row[y.count]) / Double(max(x.count, y.count))
    }

    /// Выбирает лучшую из двух расшифровок одной записи (Whisper и вторая модель).
    /// Третий, независимый движок Apple служит судьёй: побеждает тот, кто с ним заметно больше согласен.
    /// При равенстве остаётся Whisper: он знает словарь человека и второй язык фразы.
    public static func pickBest(whisper: String, other: String, reference: String, hints: [String] = []) -> String {
        if other.isEmpty { return whisper }
        if whisper.isEmpty { return other }
        // Слово из личного словаря, которое услышал только Whisper, говорит в его пользу.
        let lowerWhisper = whisper.lowercased(), lowerOther = other.lowercased()
        let knowsHint = hints.contains { hint in
            let h = hint.lowercased()
            return h.count >= 3 && lowerWhisper.contains(h) && !lowerOther.contains(h)
        }
        if knowsHint { return whisper }
        if reference.isEmpty {
            // Без судьи меняем только явно оборванный текст.
            return looksCut(exact: whisper, draft: other) ? other : whisper
        }
        if looksCut(exact: whisper, draft: reference), !looksCut(exact: other, draft: reference) { return other }
        if looksCut(exact: other, draft: reference) { return whisper }
        let margin = 0.08
        return agreement(other, reference) > agreement(whisper, reference) + margin ? other : whisper
    }

    /// Слова из конца черновика, которых нет в конце точного текста.
    /// nil, если концы совпадают или сравнить их не удаётся: тогда верим точному тексту.
    public static func missingTail(exact: String, draft: String) -> String? {
        let known = words(exact)
        let heard = words(draft)
        guard !known.isEmpty, !heard.isEmpty else { return nil }
        for length in stride(from: min(3, known.count), through: 1, by: -1) {
            // Одно слово слишком легко совпадает случайно, поэтому короткие не считаются.
            if length == 1, known[known.count - 1].count < 5 { return nil }
            let ending = Array(known.suffix(length))
            guard heard.count >= length else { continue }
            for start in stride(from: heard.count - length, through: 0, by: -1) {
                let matches = (0..<length).allSatisfy { same(ending[$0], heard[start + $0]) }
                guard matches else { continue }
                let rest = heard[(start + length)...]
                return rest.count >= (length == 1 ? 3 : 2) ? rest.joined(separator: " ") : nil
            }
        }
        return nil
    }
}

/// Ссылка для входа из письма. Открывается только адрес самого сервиса, иначе буфер обмена
/// мог бы открыть в окне входа любой сайт. Gmail иногда заворачивает ссылки в свой переход.
public enum SignInLink {
    public static func resolve(_ text: String, allowedDomains: [String]) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }
        if components.host == "www.google.com" || components.host == "google.com", components.path == "/url",
           let target = components.queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value,
           let inner = URLComponents(string: target) {
            components = inner
        }
        guard components.scheme == "https", let host = components.host?.lowercased(),
              allowedDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return components.url
    }
}
