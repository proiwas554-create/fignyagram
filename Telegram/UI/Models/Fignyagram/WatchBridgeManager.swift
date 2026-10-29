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
        return ["chats": data, "total": store.mainChatIds.count]
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
        guard message["type"] as? String == "requestChatList" else {
            replyHandler([:]); return
        }
        let limit = message["limit"] as? Int ?? 20
        Task { @MainActor in
            replyHandler(self.payload(limit: limit))
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
