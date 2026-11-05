import Foundation

public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public enum Content: Codable, Equatable, Sendable {
        case text(String)
        /// Имя PNG-файла в папке истории.
        case image(file: String, contentHash: String)
        case files([String])
    }

    public var id: UUID
    public var content: Content
    public var sourceApp: String?
    public var date: Date
    public var pinned: Bool

    public init(id: UUID = UUID(), content: Content, sourceApp: String? = nil, date: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.content = content
        self.sourceApp = sourceApp
        self.date = date
        self.pinned = pinned
    }

    /// Ключ для поиска дублей: одинаковое содержимое считается одной записью.
    var dedupKey: String {
        switch content {
        case .text(let s): return "t:" + s
        case .image(_, let hash): return "i:" + hash
        case .files(let paths): return "f:" + paths.joined(separator: "\n")
        }
    }

    public var searchableText: String {
        switch content {
        case .text(let s): return s
        case .image: return "картинка image"
        case .files(let paths): return paths.joined(separator: " ")
        }
    }
}

public struct ClipboardHistory: Codable, Equatable, Sendable {
    public private(set) var items: [ClipItem] = []
    public var limit: Int

    public init(items: [ClipItem] = [], limit: Int = 200) {
        self.items = items
        self.limit = limit
    }

    /// Добавляет запись наверх. Повтор поднимает старую запись (и сохраняет закрепление).
    /// Возвращает записи, вытесненные лимитом: у них могут быть файлы, которые надо удалить.
    @discardableResult
    public mutating func add(_ item: ClipItem) -> [ClipItem] {
        var incoming = item
        var evicted: [ClipItem] = []
        if let index = items.firstIndex(where: { $0.dedupKey == item.dedupKey }) {
            let old = items.remove(at: index)
            incoming.pinned = old.pinned
            if case .image(let oldFile, _) = old.content, case .image(let newFile, _) = item.content, oldFile != newFile {
                evicted.append(old)
            }
        }
        items.insert(incoming, at: 0)
        evicted.append(contentsOf: trim())
        return evicted
    }

    public mutating func togglePin(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
    }

    @discardableResult
    public mutating func remove(id: UUID) -> ClipItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Очищает всё, кроме закреплённого. Возвращает удалённые записи.
    @discardableResult
    public mutating func clearUnpinned() -> [ClipItem] {
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        return removed
    }

    private mutating func trim() -> [ClipItem] {
        var removed: [ClipItem] = []
        while items.count > limit, let index = items.lastIndex(where: { !$0.pinned }) {
            removed.append(items.remove(at: index))
        }
        return removed
    }

    /// Удаляет незакреплённые записи старше указанной даты. Возвращает удалённые.
    @discardableResult
    public mutating func removeOlder(than date: Date) -> [ClipItem] {
        let removed = items.filter { !$0.pinned && $0.date < date }
        items.removeAll { !$0.pinned && $0.date < date }
        return removed
    }

    /// Применяет новый лимит сразу, а не при следующем копировании.
    @discardableResult
    public mutating func applyLimit(_ newLimit: Int) -> [ClipItem] {
        limit = newLimit
        return trim()
    }

    /// Порядок показа: закреплённые сверху, дальше по свежести; поиск без учёта регистра.
    public func visible(matching query: String = "") -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = q.isEmpty ? items : items.filter { $0.searchableText.localizedCaseInsensitiveContains(q) }
        return matched.filter(\.pinned) + matched.filter { !$0.pinned }
    }
}
