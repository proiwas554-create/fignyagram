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


import SwiftUI

/// UI for the local macro engine (same rules as the terminal commands).
struct MacroSettingsView: View {
    @ObservedObject private var engine = AutomationEngine.shared
    @State private var keyword = ""
    @State private var chatIdText = ""
    @State private var action: AutomationEngine.Rule.Action = .sendSnippet
    @State private var value = ""

    var body: some View {
        Form {
            Section("Новое правило") {
                TextField("Слово в сообщении", text: $keyword)
                    .textInputAutocapitalization(.never)
                TextField("ID чата (пусто = любой)", text: $chatIdText)
                    .keyboardType(.numberPad)
                Picker("Действие", selection: $action) {
                    ForEach(AutomationEngine.Rule.Action.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                if action == .sendSnippet {
                    TextField("Текст автоответа", text: $value)
                }
                Button("Добавить") {
                    let chatId = Int64(chatIdText.trimmingCharacters(in: .whitespaces))
                    engine.addRule(chatId: chatId, keyword: keyword, action: action, value: value)
                    keyword = ""
                    chatIdText = ""
                    value = ""
                }
                .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Правила") {
                if engine.rules.isEmpty {
                    Text("Пока нет макросов").foregroundColor(.secondary)
                }
                ForEach(Array(engine.rules.enumerated()), id: \.element.id) { index, rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.keyword).font(.appBody.bold())
                        Text("чат: \(rule.chatId.map(String.init) ?? "любой") · \(rule.action.title)")
                            .font(.appFootnote)
                            .foregroundColor(.secondary)
                        if !rule.value.isEmpty {
                            Text(rule.value).font(.appFootnote)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            engine.removeRule(at: index)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }

            Section {
                Text("Правила работают локально: при входящем сообщении с нужным словом выполняется выбранное действие.")
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Автоматизация")
        .navigationBarTitleDisplayMode(.inline)
    }
}
