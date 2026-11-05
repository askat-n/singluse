import Foundation

/// Приводит распознанную речь к аккуратному тексту: убирает «э-э» и лишние пробелы, ставит заглавную букву.
public enum TranscriptCleaner {
    private static let filler = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(э+(?:-э+)*м*|м{2,}|u+m+|u+h+|e+r+m+)(?![\p{L}\p{N}])[,.…]*\s*"#,
        options: [.caseInsensitive]
    )
    private static let spaces = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([,.!?;:…])"#)

    public static func clean(_ raw: String) -> String {
        var text = raw
        text = replace(filler, in: text, with: "")
        text = replace(spaceBeforePunctuation, in: text, with: "$1")
        text = replace(spaces, in: text, with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // После удаления слова-паразита в начале могла остаться висячая пунктуация.
        while let first = text.first, ",.;:…".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
