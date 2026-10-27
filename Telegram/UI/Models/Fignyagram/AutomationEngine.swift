import Combine
import Foundation
import TDLibKit

/// Local macro engine: "message in chat X contains word Y -> run action Z".
/// Rules are stored in UserDefaults and can be managed from the terminal.
@MainActor
final class AutomationEngine: ObservableObject {
    struct Rule: Identifiable, Codable, Equatable {
        enum Action: String, Codable, CaseIterable {
            case clearCache
            case hideChat
            case sendSnippet
            case markRead

            var title: String {
                switch self {
                case .clearCache: return "очистить кэш"
                case .hideChat: return "скрыть чат"
                case .sendSnippet: return "отправить текст"
                case .markRead: return "отметить прочитанным"
                }
            }
        }

        var id = UUID()
        var chatId: Int64?          // nil = any chat
        var keyword: String
        var action: Action
        var value: String = ""
    }

    static let shared = AutomationEngine()

    @Published private(set) var rules: [Rule] = []
    private static let key = "automationRules"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = decoded
        }
    }

    @discardableResult
    func addRule(chatId: Int64?, keyword: String, action: Rule.Action, value: String = "") -> Rule? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let rule = Rule(chatId: chatId, keyword: trimmed, action: action, value: value)
        rules.append(rule)
        persist()
        return rule
    }

    func removeRule(at index: Int) {
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
        persist()
    }

    func removeAll() {
        rules.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Called for every incoming message; cheap because rules are usually empty.
    func handle(_ message: TDLibKit.Message) {
        guard !rules.isEmpty, !message.isOutgoing else { return }
        let text = Self.plainText(of: message).lowercased()
        guard !text.isEmpty else { return }
        for rule in rules {
            if let chat = rule.chatId, chat != message.chatId { continue }
            guard text.contains(rule.keyword) else { continue }
            execute(rule, message: message)
        }
    }

    private func execute(_ rule: Rule, message: TDLibKit.Message) {
        CallDiag.log("automation: rule \(rule.keyword) -> \(rule.action.rawValue) chat=\(message.chatId)")
        switch rule.action {
        case .clearCache:
            CacheManager.shared.clearAll()
        case .hideChat:
            HiddenChats.shared.hide(message.chatId)
        case .sendSnippet:
            let body = rule.value.isEmpty ? "Автоответ: \(rule.keyword)" : rule.value
            TelegramClient.shared.sendText(body, to: message.chatId)
        case .markRead:
            let chatId = message.chatId
            let messageId = message.id
            Task {
                guard let client = TelegramClient.shared.tdClient else { return }
                _ = try? await client.viewMessages(chatId: chatId,
                                                   forceRead: true,
                                                   messageIds: [messageId],
                                                   source: nil)
            }
        }
    }

    static func plainText(of message: TDLibKit.Message) -> String {
        if case .messageText(let text) = message.content { return text.text.text }
        return ""
    }
}
