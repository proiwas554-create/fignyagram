import Foundation
import TDLibKit

/// On-device extractive summary: no model download, no network, no API cost.
/// Sentences are ranked by word frequency and recency, which is enough for a
/// "what did I miss" digest of a long conversation.
nonisolated enum ConversationSummary {
    static func summarize(messages: [TDLibKit.Message], maxSentences: Int = 6) -> String {
        var texts: [String] = []
        for message in messages {
            if case .messageText(let text) = message.content {
                let value = text.text.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { texts.append(value) }
            }
        }
        return summarize(texts: texts, maxSentences: maxSentences)
    }

    static func summarize(texts: [String], maxSentences: Int = 6) -> String {
        var sentences: [String] = []
        for text in texts {
            for sentence in split(text) where sentence.split(separator: " ").count >= 4 {
                sentences.append(sentence)
            }
        }
        guard sentences.count > maxSentences else {
            return sentences.joined(separator: " ")
        }

        let stopWords: Set<String> = [
            "и", "в", "во", "не", "что", "он", "на", "я", "с", "со", "как", "а", "то",
            "все", "она", "так", "его", "но", "да", "ты", "к", "у", "же", "вы", "за",
            "бы", "по", "только", "ее", "мне", "было", "вот", "от", "меня", "еще",
            "the", "a", "an", "and", "or", "of", "to", "in", "is", "it", "that", "for"
        ]

        var frequency: [String: Int] = [:]
        for sentence in sentences {
            for word in words(in: sentence) where !stopWords.contains(word) {
                frequency[word, default: 0] += 1
            }
        }

        var scored: [(sentence: String, score: Double)] = []
        for (index, sentence) in sentences.enumerated() {
            let sentenceWords = words(in: sentence)
            let total = sentenceWords.reduce(0.0) { $0 + Double(frequency[$1] ?? 0) }
            let base = total / Double(max(1, sentenceWords.count))
            let recency = 1.0 + Double(index) / Double(max(1, sentences.count)) * 0.15
            scored.append((sentence, base * recency))
        }
        scored.sort { $0.score > $1.score }

        return scored.prefix(maxSentences).map { $0.sentence }.joined(separator: " ")
    }

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?" + "\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func words(in sentence: String) -> [String] {
        sentence.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }
}
