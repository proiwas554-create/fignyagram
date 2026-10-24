import Foundation
import Combine

/// Local-only nicknames for chats/users. Never sent to Telegram.
@MainActor
final class LocalAliases: ObservableObject {
    static let shared = LocalAliases()

    private static let chatKey = "localChatAliases"
    private static let userKey = "localUserAliases"

    @Published private(set) var chatAliases: [Int64: String] = [:]
    @Published private(set) var userAliases: [Int64: String] = [:]

    private init() {
        chatAliases = Self.load(key: Self.chatKey)
        userAliases = Self.load(key: Self.userKey)
    }

    func chatAlias(_ chatId: Int64) -> String? {
        chatAliases[chatId]
    }

    func userAlias(_ userId: Int64) -> String? {
        userAliases[userId]
    }

    func setChatAlias(_ alias: String, chatId: Int64) {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { chatAliases[chatId] = nil } else { chatAliases[chatId] = value }
        Self.save(chatAliases, key: Self.chatKey)
    }

    func setUserAlias(_ alias: String, userId: Int64) {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { userAliases[userId] = nil } else { userAliases[userId] = value }
        Self.save(userAliases, key: Self.userKey)
    }

    private static func load(key: String) -> [Int64: String] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) else { return [:] }
        var result: [Int64: String] = [:]
        for (id, value) in raw {
            if let id = Int64(id), let value = value as? String, !value.isEmpty {
                result[id] = value
            }
        }
        return result
    }

    private static func save(_ aliases: [Int64: String], key: String) {
        let raw = Dictionary(uniqueKeysWithValues: aliases.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(raw, forKey: key)
    }
}
