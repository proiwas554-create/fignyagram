import Foundation
import WatchConnectivity

/// Watch side of the bridge: asks the phone for chats and publishes them.
@MainActor
final class WatchBridgeManager: NSObject, ObservableObject {
    static let shared = WatchBridgeManager()

    @Published private(set) var chats: [WatchChat] = []
    @Published private(set) var totalChats = 0
    @Published private(set) var isReachable = false
    @Published private(set) var lastError: String?
    @Published private(set) var messages: [Int64: [WatchMessage]] = [:]
    @Published private(set) var templates: [String] = []

    private var session: WCSession?

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        // Off the first-frame path: let launch settle before WatchConnectivity
        // starts touching its queues.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, WCSession.isSupported() else { return }
            let session = WCSession.default
            session.delegate = self
            session.activate()
            self.session = session
        }
    }

    func requestChats(limit: Int) {
        guard let session, session.activationState == .activated else { return }
        let message: [String: Any] = ["type": "requestChatList", "limit": limit]
        if session.isReachable {
            session.sendMessage(message, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.apply(reply) }
            }, errorHandler: { [weak self] error in
                Task { @MainActor in self?.lastError = error.localizedDescription }
            })
        } else {
            session.transferUserInfo(message)
        }
    }

    func requestMessages(chatId: Int64, limit: Int) {
        guard let session, session.activationState == .activated else { return }
        let message: [String: Any] = ["type": "requestMessages", "chatId": chatId, "limit": limit]
        if session.isReachable {
            session.sendMessage(message, replyHandler: { [weak self] reply in
                Task { @MainActor in self?.applyMessages(chatId: chatId, reply) }
            }, errorHandler: { [weak self] error in
                Task { @MainActor in self?.lastError = error.localizedDescription }
            })
        } else {
            session.transferUserInfo(message)
        }
    }

    func requestTemplates() {
        guard let session, session.isReachable else { return }
        session.sendMessage(["type": "requestTemplates"], replyHandler: { [weak self] reply in
            Task { @MainActor in
                self?.templates = (reply["templates"] as? [String]) ?? []
            }
        }, errorHandler: nil)
    }

    func sendWatchMessage(chatId: Int64, text: String) {
        guard let session, session.isReachable else { return }
        session.sendMessage(["type": "sendWatchMessage", "chatId": chatId, "text": text],
                            replyHandler: nil,
                            errorHandler: { [weak self] error in
                                Task { @MainActor in self?.lastError = error.localizedDescription }
                            })
    }

    private func applyMessages(chatId: Int64, _ reply: [String: Any]) {
        guard let data = reply["messages"] as? Data,
              let decoded = try? JSONDecoder().decode([WatchMessage].self, from: data) else { return }
        messages[chatId] = decoded
    }

    private func apply(_ reply: [String: Any]) {
        guard let data = reply["chats"] as? Data else { return }
        if let decoded = try? JSONDecoder().decode([WatchChat].self, from: data) {
            chats = decoded
        }
        totalChats = reply["total"] as? Int ?? chats.count
        if let templates = reply["templates"] as? [String] { self.templates = templates }
        lastError = nil
    }
}

extension WatchBridgeManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            self.requestChats(limit: 20)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.apply(userInfo) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.isReachable = session.isReachable }
    }
}
