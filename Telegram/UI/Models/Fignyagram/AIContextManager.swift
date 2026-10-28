import Foundation
import NaturalLanguage
import TDLibKit

/// On-device analysis of a conversation using Apple's NaturalLanguage.
/// Produces a structured digest: topics, key points and action items.
/// Nothing leaves the device and no API is called.
nonisolated enum AIContextManager {
    struct Digest {
        var topics: [String]
        var points: [String]
        var actions: [String]

        var text: String {
            var parts: [String] = []
            if !topics.isEmpty {
                parts.append("Темы: " + topics.joined(separator: ", "))
            }
            if !points.isEmpty {
                parts.append("Тезисы:\n" + points.map { "• \($0)" }.joined(separator: "\n"))
            }
            if !actions.isEmpty {
                parts.append("Поручения:\n" + actions.map { "→ \($0)" }.joined(separator: "\n"))
            }
            return parts.isEmpty ? "Недостаточно текста для анализа." : parts.joined(separator: "\n\n")
        }
    }

    static func summarize(messages: [String]) -> String {
        digest(messages: messages).text
    }

    static func digest(messages: [String]) -> Digest {
        let text = messages.joined(separator: "\n")
        guard text.count > 40 else { return Digest(topics: [], points: [], actions: []) }

        let sentences = splitSentences(text)
        let topics = extractTopics(text, limit: 6)
        let actions = sentences.filter { isActionItem($0) }
        let points = rankSentences(sentences, limit: 6)

        return Digest(topics: topics,
                      points: points,
                      actions: Array(actions.prefix(4)))
    }

    // MARK: - NaturalLanguage helpers

    private static func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count > 12 { result.append(sentence) }
            return true
        }
        return result
    }

    private static func extractTopics(_ text: String, limit: Int) -> [String] {
        var frequency: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .lexicalClass,
                             options: options) { tag, range in
            guard tag == .noun else { return true }
            let word = String(text[range]).lowercased()
            guard word.count > 2, !stopWords.contains(word) else { return true }
            frequency[word, default: 0] += 1
            return true
        }
        return frequency
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key }
    }

    private static func rankSentences(_ sentences: [String], limit: Int) -> [String] {
        var frequency: [String: Int] = [:]
        for sentence in sentences {
            for word in words(sentence) where !stopWords.contains(word) {
                frequency[word, default: 0] += 1
            }
        }
        let scored = sentences.map { sentence -> (String, Double) in
            let list = words(sentence)
            let total = list.reduce(0.0) { $0 + Double(frequency[$1] ?? 0) }
            return (sentence, total / Double(max(1, list.count)))
        }
        .sorted { $0.1 > $1.1 }
        return scored.prefix(limit).map { $0.0 }
    }

    private static func isActionItem(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        let markers = ["нужно", "надо", "сделай", "сделать", "проверь", "проверить",
                       "добавь", "добавить", "исправь", "исправить", "позвони", "позвонить",
                       "напиши", "отправь", "подготовь", "до ", "дедлайн", "deadline",
                       "please", "could you", "todo", "task"]
        return markers.contains { lower.contains($0) }
    }

    private static func words(_ sentence: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        var result: [String] = []
        tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { range, _ in
            let word = String(sentence[range]).lowercased()
            if word.count > 1 { result.append(word) }
            return true
        }
        return result
    }

    private static let stopWords: Set<String> = [
        "и", "в", "во", "не", "что", "он", "на", "я", "с", "со", "как", "а", "то",
        "все", "она", "так", "его", "но", "да", "ты", "к", "у", "же", "вы", "за",
        "бы", "по", "только", "ее", "мне", "было", "вот", "от", "меня", "еще",
        "это", "этот", "эта", "для", "или", "если", "когда", "the", "a", "an",
        "and", "or", "of", "to", "in", "is", "it", "that", "for", "you", "i"
    ]
}


import SwiftUI

/// Chat-menu entry: structured on-device digest.
struct AIDigestView: View {
    let digestText: String
    @Environment(\.dismiss) private var dismiss
    @State private var isAnimating = false

    var body: some View {
        NavigationView {
            ScrollView {
                Text(digestText)
                    .font(.appBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("AI-выжимка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
