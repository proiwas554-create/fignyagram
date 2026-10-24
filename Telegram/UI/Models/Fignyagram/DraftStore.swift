import Foundation
import Combine

@MainActor
final class DraftStore: ObservableObject {
    static let shared = DraftStore()
    private static let key = "messageDrafts"

    @Published private(set) var drafts: [String: String] = [:]

    private init() {
        drafts = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func draft(for chatId: Int64) -> String {
        drafts["\(chatId)"] ?? ""
    }

    func save(_ text: String, for chatId: Int64) {
        let key = "\(chatId)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts.removeValue(forKey: key)
        } else {
            drafts[key] = text
        }
        persist()
    }

    func clear(for chatId: Int64) {
        drafts.removeValue(forKey: "\(chatId)")
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(drafts, forKey: Self.key)
    }
}
