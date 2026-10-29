import Combine
import Foundation
@preconcurrency import WatchConnectivity
import TDLibKit

/// iPhone side of the watch bridge: answers chat-list requests with a compact
/// JSON payload, already translated by AutoTranslationManager.
@objcMembers
final class WatchBridgeManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchBridgeManager()

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @MainActor private func messagesPayload(chatId: Int64, limit: Int) -> [String: Any] {
        let store = ChatStore.shared
        let source = store.messages[chatId] ?? []
        let slice = Array(source.suffix(max(1, limit)))
        let messages: [WatchMessage] = slice.map { message in
            let base = MessageFormatter.preview(message.content)
            let text = AutoTranslationManager.shared
                .translation(for: message, text: base, role: "body") ?? base
            return WatchMessage(id: message.id,
                                text: text,
                                senderName: store.senderName(message.senderId),
                                isOutgoing: message.isOutgoing,
                                timestamp: message.date)
        }
        let data = (try? JSONEncoder().encode(messages)) ?? Data()
        return ["messages": data]
    }

    @MainActor private func send(text: String, to chatId: Int64) {
        TelegramClient.shared.sendText(text, to: chatId)
        if TelegramClient.shared.isInvisible {
            TelegramClient.shared.setOnline(false)
        }
    }

    @MainActor private func payload(limit: Int) -> [String: Any] {
        let store = ChatStore.shared
        let ids = Array(store.mainChatIds.prefix(max(1, limit)))
        let chats: [WatchChat] = ids.compactMap { chatId -> WatchChat? in
            guard let chat = store.chats[chatId] else { return nil }
            let baseTitle = chat.title
            let title = AutoTranslationManager.shared
                .translation(forChatId: chatId, title: baseTitle) ?? baseTitle
            var preview = ""
            if let message = chat.lastMessage {
                preview = MessageFormatter.preview(message.content)
                if let cached = AutoTranslationManager.shared
                    .translation(for: message, text: preview, role: "body") {
                    preview = cached
                }
            }
            return WatchChat(id: chatId,
                             title: title,
                             preview: preview,
                             unread: chat.unreadCount,
                             isPinned: chat.isPinned,
                             isMuted: false)
        }
        let data = (try? JSONEncoder().encode(chats)) ?? Data()
        return ["chats": data,
                "total": store.mainChatIds.count,
                "templates": SnippetsStore.shared.snippets]
    }
}

extension WatchBridgeManager {
    nonisolated func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Swift.Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let type = message["type"] as? String else { replyHandler([:]); return }
        switch type {
        case "requestChatList":
            let limit = message["limit"] as? Int ?? 20
            Task { @MainActor in replyHandler(self.payload(limit: limit)) }
        case "requestMessages":
            let chatId = (message["chatId"] as? Int64) ?? Int64(message["chatId"] as? Int ?? 0)
            let limit = message["limit"] as? Int ?? 40
            Task { @MainActor in replyHandler(self.messagesPayload(chatId: chatId, limit: limit)) }
        case "sendWatchMessage":
            let chatId = (message["chatId"] as? Int64) ?? Int64(message["chatId"] as? Int ?? 0)
            let text = message["text"] as? String ?? ""
            Task { @MainActor in
                self.send(text: text, to: chatId)
                replyHandler(["ok": true])
            }
        case "requestTemplates":
            Task { @MainActor in replyHandler(["templates": SnippetsStore.shared.snippets]) }
        default:
            replyHandler([:])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo["type"] as? String == "requestChatList" else { return }
        let limit = userInfo["limit"] as? Int ?? 20
        Task { @MainActor in
            session.transferUserInfo(self.payload(limit: limit))
        }
    }
}
