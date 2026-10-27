import Foundation

/// Detects a sensible file extension for text that is sent as a document, so
/// code snippets arrive as .swift/.py/.js/.html/.json instead of a plain .txt
/// and get syntax highlighting inside Telegram.
nonisolated enum TextFileHeuristics {
    static func suggestedExtension(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("<?php") { return "php" }
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") { return "html" }
        if (lower.hasPrefix("{") || lower.hasPrefix("[")), isJSON(trimmed) { return "json" }
        if lower.hasPrefix("def ") || lower.hasPrefix("class ") || lower.hasPrefix("import ") {
            // Swift also starts with `import`, so check the Swift-only markers first.
            if lower.contains("import swiftui") || lower.contains("import uikit")
                || lower.contains("struct ") || lower.contains("func ") || lower.contains("@main") {
                return "swift"
            }
            if lower.contains("<?php") { return "php" }
            return "py"
        }
        if lower.hasPrefix("function ") || lower.hasPrefix("const ") || lower.hasPrefix("let ")
            || lower.hasPrefix("export ") || lower.hasPrefix("async function") {
            return "js"
        }
        if lower.contains("import swiftui") || lower.contains("import foundation")
            || lower.contains("import uikit") || lower.contains("@main") {
            return "swift"
        }
        return "txt"
    }

    static func fileName(timestamp: Int = Int(Foundation.Date().timeIntervalSince1970)) -> (name: String, ext: String) {
        (name: "message-\(timestamp)", ext: "txt")
    }

    private static func isJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }
}

/// One-tap text transformations above the composer.
nonisolated enum TextTransformers {
    static func reversed(_ text: String) -> String {
        String(text.reversed())
    }

    static func spongebob(_ text: String) -> String {
        var upper = false
        return String(text.map { character in
            defer { upper.toggle() }
            guard character.isLetter else { return character }
            return upper ? Character(String(character).uppercased())
                         : Character(String(character).lowercased())
        })
    }

    static func collapsedSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
