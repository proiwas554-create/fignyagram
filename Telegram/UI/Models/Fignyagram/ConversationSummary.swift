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
            NSLocalizedString("Generated.2b60d1b4fb51", comment: ""), NSLocalizedString("Generated.9c1194bf4d63", comment: ""), NSLocalizedString("Generated.0ca2ffb49efb", comment: ""), NSLocalizedString("Generated.8cda951004df", comment: ""), NSLocalizedString("Generated.275f5a4869c3", comment: ""), NSLocalizedString("Generated.afc91013dc96", comment: ""), NSLocalizedString("Generated.02f5ddae6fe2", comment: ""), NSLocalizedString("Generated.4e0636098516", comment: ""), NSLocalizedString("Generated.be2e37114dec", comment: ""), NSLocalizedString("Generated.d2df1f8da7e4", comment: ""), NSLocalizedString("Generated.6d3853d2635d", comment: ""), NSLocalizedString("Generated.1acd5550d3ed", comment: ""), NSLocalizedString("Generated.5f316e8cff2c", comment: ""),
            NSLocalizedString("Generated.6459ea4cf837", comment: ""), NSLocalizedString("Generated.364fbfcd01e6", comment: ""), NSLocalizedString("Generated.91e4480c372e", comment: ""), NSLocalizedString("Generated.1f98beaf4985", comment: ""), NSLocalizedString("Generated.27675a55978d", comment: ""), NSLocalizedString("Generated.f98d379ce4ff", comment: ""), NSLocalizedString("Generated.a5ddcb940dc2", comment: ""), NSLocalizedString("Generated.02265bcfa837", comment: ""), NSLocalizedString("Generated.5f570aaf5197", comment: ""), NSLocalizedString("Generated.3a0a63c87312", comment: ""), NSLocalizedString("Generated.2b8b30366d09", comment: ""), NSLocalizedString("Generated.2f8c2dbf1de3", comment: ""),
            NSLocalizedString("Generated.c0228c9cefe9", comment: ""), NSLocalizedString("Generated.32b5e2cbdc2a", comment: ""), NSLocalizedString("Generated.d9338b35273e", comment: ""), NSLocalizedString("Generated.fc1bc005b7ba", comment: ""), NSLocalizedString("Generated.6cc4859f25cd", comment: ""), NSLocalizedString("Generated.4dd43e2d53d9", comment: ""), NSLocalizedString("Generated.9e8bc8ba3933", comment: ""), NSLocalizedString("Generated.d428aca76100", comment: ""), NSLocalizedString("Generated.444757bc968e", comment: ""), NSLocalizedString("Generated.28c8a2aaa110", comment: ""),
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
