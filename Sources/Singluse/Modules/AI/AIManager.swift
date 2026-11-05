import AppKit
import Foundation
import Security
import SwiftUI

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, openai, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "ChatGPT"
        case .gemini: return "Gemini"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .openai: return "bubble.left.and.text.bubble.right.fill"
        case .gemini: return "wand.and.stars"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .openai: return Color(red: 0.06, green: 0.64, blue: 0.5)
        case .gemini: return .blue
        }
    }

    /// Названия моделей меняются часто, поэтому после проверки ключа список приходит от самого сервиса.
    var defaultModel: String {
        switch self {
        case .claude: return "claude-opus-5-5"
        case .openai: return "gpt-6-luna"
        case .gemini: return "gemini-flash-latest"
        }
    }

    var keysURL: URL {
        switch self {
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    /// Страница, где сам сервис показывает лимиты подписки или использования.
    var limitsURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .openai: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .gemini: return URL(string: "https://aistudio.google.com/usage")!
        }
    }

    /// С каких сайтов может прийти ссылка для входа.
    var signInDomains: [String] {
        switch self {
        case .claude: return ["claude.ai", "claude.com", "anthropic.com"]
        case .openai: return ["chatgpt.com", "openai.com"]
        case .gemini: return ["google.com"]
        }
    }

    var limitsTitle: String {
        switch self {
        case .claude: return L("Лимиты подписки Claude")
        case .openai: return L("Лимиты ChatGPT и Codex")
        case .gemini: return L("Использование Gemini API")
        }
    }

    var supportsSpendReport: Bool { self != .gemini }

    var adminKeyHint: String {
        switch self {
        case .claude: return L("Admin-ключ (sk-ant-admin…) из Claude Console")
        case .openai: return L("Admin-ключ из настроек организации OpenAI")
        case .gemini: return ""
        }
    }
}

/// Ключи хранятся только в Связке ключей macOS и никуда не передаются, кроме самого сервиса.
enum KeyStore {
    private static let service = "com.askatbek.singluse.ai"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Запросы к сервисам. Модели и пути разные, поэтому у каждого свой код без общей абстракции.
enum AIClient {
    private static let anthropicVersion = "2026-10-21"

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            switch status {
            case 401, 403: throw AIError(message: String(format: L("Ключ не подошёл (%lld)"), status))
            case 429: throw AIError(message: L("Лимит запросов исчерпан (429)"))
            default:
                let detail = (json["error"] as? [String: Any])?["message"] as? String
                throw AIError(message: detail ?? String(format: L("Ошибка сервиса (%lld)"), status))
            }
        }
        return json
    }

    private static func anthropicRequest(_ path: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com\(path)")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("Singluse/0.2", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func postJSON(_ request: inout URLRequest, _ body: [String: Any]) throws {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    /// Список моделей заодно служит бесплатной проверкой ключа.
    static func models(_ provider: AIProvider, key: String) async throws -> [String] {
        switch provider {
        case .claude:
            let json = try await send(anthropicRequest("/v1/models?limit=100", key: key))
            return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        case .openai:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let json = try await send(request)
            return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                .filter { $0.hasPrefix("gpt") && !$0.contains("transcribe") && !$0.contains("audio") && !$0.contains("realtime") && !$0.contains("image") && !$0.contains("tts") }
                .sorted()
        case .gemini:
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let json = try await send(request)
            return (json["models"] as? [[String: Any]] ?? []).compactMap { model -> String? in
                guard let methods = model["supportedGenerationMethods"] as? [String], methods.contains("generateContent") else { return nil }
                return (model["name"] as? String)?.replacingOccurrences(of: "models/", with: "")
            }
        }
    }

    /// Короткий текстовый запрос. Текст пользователя передаётся отдельно от инструкции.
    static func complete(_ provider: AIProvider, key: String, model: String, system: String, text: String) async throws -> String {
        switch provider {
        case .claude:
            var request = anthropicRequest("/v1/messages", key: key)
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 16000,
                "system": system,
                "output_config": ["effort": "low"],
                "messages": [["role": "user", "content": text]],
            ]
            // Серверный запасной маршрут при отказе классификаторов; у Haiku его нет.
            if model.contains("opus") || model.contains("fable") || model.contains("sonnet-5-5") {
                body["fallbacks"] = "default"
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
            try postJSON(&request, body)
            let json = try await send(request)
            if json["stop_reason"] as? String == "refusal" { throw AIError(message: L("Claude отказался обрабатывать текст")) }
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .openai:
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            try postJSON(&request, [
                "model": model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": text]],
            ])
            let json = try await send(request)
            let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            return message?["content"] as? String ?? ""
        case .gemini:
            let safeModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(safeModel):generateContent")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            try postJSON(&request, [
                "system_instruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": text]]]],
            ])
            let json = try await send(request)
            let content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            return parts.compactMap { $0["text"] as? String }.joined()
        }
    }

    /// Облачное распознавание: тот же класс качества, что у Wispr Flow.
    static func transcribe(wav: Data, key: String, language: String, hints: [String]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let boundary = "singluse-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", "gpt-transcribe")
        field("language", language)
        if !hints.isEmpty { field("prompt", hints.joined(separator: ", ")) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let json = try await send(request)
        return json["text"] as? String ?? ""
    }

    /// Траты за дни, начиная с указанного момента, в долларах. Нужен admin-ключ.
    static func dailySpend(_ provider: AIProvider, adminKey: String, days: Int) async throws -> [(date: Date, usd: Double)] {
        let start = Calendar.current.startOfDay(for: Date(timeIntervalSinceNow: -Double(days) * 86400))
        var result: [(Date, Double)] = []
        var page: String?
        switch provider {
        case .claude:
            let formatter = ISO8601DateFormatter()
            repeat {
                var path = "/v1/organizations/cost_report?starting_at=\(formatter.string(from: start))&bucket_width=1d&limit=31"
                if let page { path += "&page=\(page)" }
                let json = try await send(anthropicRequest(path, key: adminKey))
                for bucket in json["data"] as? [[String: Any]] ?? [] {
                    let date = (bucket["starting_at"] as? String).flatMap(formatter.date) ?? start
                    // Суммы приходят строкой в центах.
                    let cents = (bucket["results"] as? [[String: Any]] ?? []).reduce(0.0) { sum, row in
                        sum + (Double(row["amount"] as? String ?? "") ?? 0)
                    }
                    result.append((date, cents / 100))
                }
                page = (json["has_more"] as? Bool == true) ? json["next_page"] as? String : nil
            } while page != nil
        case .openai:
            repeat {
                var urlString = "https://api.openai.com/v1/organization/costs?start_time=\(Int(start.timeIntervalSince1970))&bucket_width=1d&limit=31"
                if let page { urlString += "&page=\(page)" }
                var request = URLRequest(url: URL(string: urlString)!)
                request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
                let json = try await send(request)
                for bucket in json["data"] as? [[String: Any]] ?? [] {
                    let date = Date(timeIntervalSince1970: bucket["start_time"] as? Double ?? start.timeIntervalSince1970)
                    let usd = (bucket["results"] as? [[String: Any]] ?? []).reduce(0.0) { sum, row in
                        sum + (((row["amount"] as? [String: Any])?["value"] as? Double) ?? 0)
                    }
                    result.append((date, usd))
                }
                page = json["next_page"] as? String
            } while page != nil
        case .gemini:
            throw AIError(message: L("Google не даёт такого отчёта по ключу"))
        }
        return result
    }
}

struct AISpend: Equatable {
    var week: Double
    var month: Double
    var updated: Date
}

@MainActor
final class AIManager: ObservableObject {
    @Published private(set) var hasKey: Set<AIProvider> = []
    @Published private(set) var hasAdminKey: Set<AIProvider> = []
    @Published private(set) var models: [AIProvider: [String]] = [:]
    @Published private(set) var spend: [AIProvider: AISpend] = [:]
    @Published private(set) var status: [AIProvider: String] = [:]
    @Published private(set) var busy: Set<AIProvider> = []
    private let d = UserDefaults.standard

    init() {
        for provider in AIProvider.allCases {
            if KeyStore.read(keyAccount(provider)) != nil { hasKey.insert(provider) }
            if KeyStore.read(adminAccount(provider)) != nil { hasAdminKey.insert(provider) }
        }
    }

    private func keyAccount(_ provider: AIProvider) -> String { "\(provider.rawValue).key" }
    private func adminAccount(_ provider: AIProvider) -> String { "\(provider.rawValue).admin" }

    func key(_ provider: AIProvider) -> String? { KeyStore.read(keyAccount(provider)) }

    func model(_ provider: AIProvider) -> String {
        d.string(forKey: "ai.\(provider.rawValue).model") ?? provider.defaultModel
    }

    func setModel(_ value: String, for provider: AIProvider) {
        objectWillChange.send()
        d.set(value, forKey: "ai.\(provider.rawValue).model")
    }

    /// Лимиты, которые человек задаёт сам: сервисы не отдают их через API.
    func budget(_ provider: AIProvider, weekly: Bool) -> Double {
        d.double(forKey: "ai.\(provider.rawValue).\(weekly ? "weekly" : "total")")
    }

    func setBudget(_ value: Double, for provider: AIProvider, weekly: Bool) {
        objectWillChange.send()
        d.set(value, forKey: "ai.\(provider.rawValue).\(weekly ? "weekly" : "total")")
    }

    func saveKey(_ value: String, for provider: AIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeyStore.write(trimmed, account: keyAccount(provider))
        hasKey.insert(provider)
        Task { await verify(provider) }
    }

    func saveAdminKey(_ value: String, for provider: AIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeyStore.write(trimmed, account: adminAccount(provider))
        hasAdminKey.insert(provider)
        Task { await refreshSpend(provider) }
    }

    func removeKeys(for provider: AIProvider) {
        KeyStore.delete(keyAccount(provider))
        KeyStore.delete(adminAccount(provider))
        hasKey.remove(provider)
        hasAdminKey.remove(provider)
        models[provider] = nil
        spend[provider] = nil
        status[provider] = nil
    }

    func verify(_ provider: AIProvider) async {
        guard let key = key(provider) else { return }
        busy.insert(provider)
        defer { busy.remove(provider) }
        do {
            let list = try await AIClient.models(provider, key: key)
            models[provider] = list
            status[provider] = L("Подключено")
        } catch {
            status[provider] = error.localizedDescription
        }
    }

    func refreshSpend(_ provider: AIProvider) async {
        guard provider.supportsSpendReport, let admin = KeyStore.read(adminAccount(provider)) else { return }
        busy.insert(provider)
        defer { busy.remove(provider) }
        do {
            let rows = try await AIClient.dailySpend(provider, adminKey: admin, days: 31)
            let weekStart = Date(timeIntervalSinceNow: -7 * 86400)
            let week = rows.filter { $0.date >= weekStart }.reduce(0) { $0 + $1.usd }
            let month = rows.reduce(0) { $0 + $1.usd }
            spend[provider] = AISpend(week: week, month: month, updated: Date())
        } catch {
            status[provider] = error.localizedDescription
        }
    }

    func refreshAll() {
        for provider in hasKey { Task { await verify(provider) } }
        for provider in hasAdminKey { Task { await refreshSpend(provider) } }
    }
}
