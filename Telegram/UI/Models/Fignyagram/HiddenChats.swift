import Combine
import Foundation

/// Locally hidden chats. A hidden chat disappears from the main list and can
/// only be revealed from the developer terminal with
/// `/open_secret_chat_<id>` (or `/hide_secret_chat_<id>` to hide it again).
@MainActor
final class HiddenChats: ObservableObject {
    static let shared = HiddenChats()

    private enum Keys {
        static let hidden = "hiddenChatIds"
        static let revealed = "revealedChatIds"
    }

    @Published private(set) var hiddenIds: Set<Int64> = []
    /// Temporarily revealed chats (this session only).
    @Published private(set) var revealedIds: Set<Int64> = []

    private init() {
        if let stored = UserDefaults.standard.array(forKey: Keys.hidden) as? [NSNumber] {
            hiddenIds = Set(stored.map(\.int64Value))
        }
    }

    func hide(_ chatId: Int64) {
        hiddenIds.insert(chatId)
        revealedIds.remove(chatId)
        persist()
    }

    func unhide(_ chatId: Int64) {
        hiddenIds.remove(chatId)
        revealedIds.remove(chatId)
        persist()
    }

    func reveal(_ chatId: Int64) {
        revealedIds.insert(chatId)
        objectWillChange.send()
    }

    func isVisible(_ chatId: Int64) -> Bool {
        !hiddenIds.contains(chatId) || revealedIds.contains(chatId)
    }

    private func persist() {
        UserDefaults.standard.set(hiddenIds.map { NSNumber(value: $0) }, forKey: Keys.hidden)
    }
}
