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
                parts.append(NSLocalizedString("Generated.b91b0660db32", comment: "") + topics.joined(separator: ", "))
            }
            if !points.isEmpty {
                parts.append("Тезисы:\n" + points.map { "• \($0)" }.joined(separator: "\n"))
            }
            if !actions.isEmpty {
                parts.append("Поручения:\n" + actions.map { "→ \($0)" }.joined(separator: "\n"))
            }
            return parts.isEmpty ? NSLocalizedString("Generated.6384068076fd", comment: "") : parts.joined(separator: "\n\n")
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
        let markers = [NSLocalizedString("Generated.73580ac4eb3d", comment: ""), NSLocalizedString("Generated.1c10c3064e9c", comment: ""), NSLocalizedString("Generated.c227ffcfb8ce", comment: ""), NSLocalizedString("Generated.edb5ad87ad02", comment: ""), NSLocalizedString("Generated.afb1f809fe1d", comment: ""), NSLocalizedString("Generated.c9b582a8aa97", comment: ""),
                       NSLocalizedString("Generated.44b51afa1196", comment: ""), NSLocalizedString("Generated.c28759774db4", comment: ""), NSLocalizedString("Generated.4e58242c278d", comment: ""), NSLocalizedString("Generated.8f841cd05670", comment: ""), NSLocalizedString("Generated.42ae89ef9849", comment: ""), NSLocalizedString("Generated.c2e3bef725c2", comment: ""),
                       NSLocalizedString("Generated.1f3f5365638a", comment: ""), NSLocalizedString("Generated.2f35f4583840", comment: ""), NSLocalizedString("Generated.c559d7f4bf1a", comment: ""), NSLocalizedString("Generated.71a6dee1f33a", comment: ""), NSLocalizedString("Generated.cb2b010c09ff", comment: ""), "deadline",
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
        NSLocalizedString("Generated.2b60d1b4fb51", comment: ""), NSLocalizedString("Generated.9c1194bf4d63", comment: ""), NSLocalizedString("Generated.0ca2ffb49efb", comment: ""), NSLocalizedString("Generated.8cda951004df", comment: ""), NSLocalizedString("Generated.275f5a4869c3", comment: ""), NSLocalizedString("Generated.afc91013dc96", comment: ""), NSLocalizedString("Generated.02f5ddae6fe2", comment: ""), NSLocalizedString("Generated.4e0636098516", comment: ""), NSLocalizedString("Generated.be2e37114dec", comment: ""), NSLocalizedString("Generated.d2df1f8da7e4", comment: ""), NSLocalizedString("Generated.6d3853d2635d", comment: ""), NSLocalizedString("Generated.1acd5550d3ed", comment: ""), NSLocalizedString("Generated.5f316e8cff2c", comment: ""),
        NSLocalizedString("Generated.6459ea4cf837", comment: ""), NSLocalizedString("Generated.364fbfcd01e6", comment: ""), NSLocalizedString("Generated.91e4480c372e", comment: ""), NSLocalizedString("Generated.1f98beaf4985", comment: ""), NSLocalizedString("Generated.27675a55978d", comment: ""), NSLocalizedString("Generated.f98d379ce4ff", comment: ""), NSLocalizedString("Generated.a5ddcb940dc2", comment: ""), NSLocalizedString("Generated.02265bcfa837", comment: ""), NSLocalizedString("Generated.5f570aaf5197", comment: ""), NSLocalizedString("Generated.3a0a63c87312", comment: ""), NSLocalizedString("Generated.2b8b30366d09", comment: ""), NSLocalizedString("Generated.2f8c2dbf1de3", comment: ""),
        NSLocalizedString("Generated.c0228c9cefe9", comment: ""), NSLocalizedString("Generated.32b5e2cbdc2a", comment: ""), NSLocalizedString("Generated.d9338b35273e", comment: ""), NSLocalizedString("Generated.fc1bc005b7ba", comment: ""), NSLocalizedString("Generated.6cc4859f25cd", comment: ""), NSLocalizedString("Generated.4dd43e2d53d9", comment: ""), NSLocalizedString("Generated.9e8bc8ba3933", comment: ""), NSLocalizedString("Generated.d428aca76100", comment: ""), NSLocalizedString("Generated.444757bc968e", comment: ""), NSLocalizedString("Generated.28c8a2aaa110", comment: ""),
        NSLocalizedString("Generated.90baa1058cfd", comment: ""), NSLocalizedString("Generated.d72a212e8691", comment: ""), NSLocalizedString("Generated.939ada25cde1", comment: ""), NSLocalizedString("Generated.3d1332db6391", comment: ""), NSLocalizedString("Generated.61a31eebeb18", comment: ""), NSLocalizedString("Generated.8d19bc9952b2", comment: ""), NSLocalizedString("Generated.42d7fbfe3205", comment: ""), "the", "a", "an",
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
            .navigationTitle(L10n.t("Auto.9d6b1eafb1"))
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
