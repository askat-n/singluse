import Foundation

/// Номер версии вида «1.2.3». Метки релизов на GitHub пишутся как «v1.2.3» — буква отбрасывается.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var raw = text.trimmingCharacters(in: .whitespaces)
        if raw.first == "v" || raw.first == "V" { raw.removeFirst() }
        // «1.2-beta» сравнивается по числовой части.
        let numeric = raw.prefix { $0.isNumber || $0 == "." }
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    /// 1.0 и 1.0.0 — одна и та же версия.
    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for i in 0..<count {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// Последний релиз с GitHub в том виде, который нужен приложению.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let pageURL: URL
    public let downloadURL: URL?

    public static func == (lhs: ReleaseInfo, rhs: ReleaseInfo) -> Bool {
        lhs.version == rhs.version && lhs.downloadURL == rhs.downloadURL
    }

    /// Разбирает ответ `GET /repos/{owner}/{repo}/releases/latest`.
    /// Черновики и пре-релизы не считаются: пользователю предлагается только готовая версия.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String, let version = AppVersion(tag),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
        let download = (zip?["browser_download_url"] as? String).flatMap(URL.init(string:))
        // Скачивать разрешено только с самого GitHub.
        let trusted = download.flatMap { url -> URL? in
            guard url.scheme == "https", let host = url.host, host == "github.com" || host.hasSuffix(".githubusercontent.com") else { return nil }
            return url
        }
        return ReleaseInfo(version: version, notes: json["body"] as? String ?? "", pageURL: page, downloadURL: trusted)
    }
}
