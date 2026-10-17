import Foundation
import Combine
import TDLibKit

struct ChatItem: Identifiable, Equatable {
    let id: Int64
    var title: String
    var type: ChatType
    var photo: ChatPhotoInfo?
    var lastMessage: Message?
    var positions: [ChatPosition]
    var unreadCount: Int
    var lastReadInboxMessageId: Int64
    var lastReadOutboxMessageId: Int64
    var isMarkedAsUnread: Bool

    init(_ chat: Chat) {
        id = chat.id
        title = chat.title
        type = chat.type
        photo = chat.photo
        lastMessage = chat.lastMessage
        positions = chat.positions
        unreadCount = chat.unreadCount
        lastReadInboxMessageId = chat.lastReadInboxMessageId
        lastReadOutboxMessageId = chat.lastReadOutboxMessageId
        isMarkedAsUnread = chat.isMarkedAsUnread
    }

    var mainPosition: ChatPosition? {
        positions.first { $0.list == .chatListMain }
    }

    var isPinned: Bool { mainPosition?.isPinned ?? false }

    var isChannel: Bool {
        if case .chatTypeSupergroup(let s) = type { return s.isChannel }
        return false
    }

    var isGroup: Bool {
        switch type {
        case .chatTypeBasicGroup: return true
        case .chatTypeSupergroup(let s): return !s.isChannel
        default: return false
        }
    }

    var privateUserId: Int64? {
        switch type {
        case .chatTypePrivate(let p): return p.userId
        case .chatTypeSecret(let s): return s.userId
        default: return nil
        }
    }
}

@MainActor
final class ChatStore: ObservableObject {

    static let shared = ChatStore()
    private init() {}

    @Published private(set) var chats: [Int64: ChatItem] = [:]
    /// Chats of the main list, sorted the same way as in official clients.
    @Published private(set) var mainChatIds: [Int64] = []
    /// chatId → messages sorted from oldest to newest.
    @Published private(set) var messages: [Int64: [Message]] = [:]
    @Published private(set) var users: [Int64: User] = [:]
    @Published private(set) var files: [Int: File] = [:]

    @Published var loadingChats: Set<Int64> = []
    /// Chats whose history has been loaded up to the very first message.
    @Published var fullyLoadedChats: Set<Int64> = []

    func reset() {
        chats = [:]
        mainChatIds = []
        messages = [:]
        users = [:]
        files = [:]
        loadingChats = []
        fullyLoadedChats = []
    }

    // MARK: - Chats

    func addChat(_ chat: Chat) {
        chats[chat.id] = ChatItem(chat)
        recomputeOrder()
    }

    func updateChat(_ chatId: Int64, reorder: Bool = false, _ change: (inout ChatItem) -> Void) {
        guard var chat = chats[chatId] else { return }
        change(&chat)
        chats[chatId] = chat
        if reorder { recomputeOrder() }
    }

    func setPosition(chatId: Int64, position: ChatPosition) {
        updateChat(chatId, reorder: true) { chat in
            chat.positions.removeAll { $0.list == position.list }
            if position.order.rawValue != 0 {
                chat.positions.append(position)
            }
        }
    }

    private func recomputeOrder() {
        let sorted = chats.values
            .compactMap { chat -> (Int64, Int64)? in
                guard let order = chat.mainPosition?.order.rawValue, order != 0 else { return nil }
                return (chat.id, order)
            }
            .sorted { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1 }
            .map { $0.0 }
        if sorted != mainChatIds {
            mainChatIds = sorted
        }
    }

    // MARK: - Messages

    func isHistoryLoaded(_ chatId: Int64) -> Bool {
        messages[chatId] != nil
    }

    func setHistory(chatId: Int64, messages newMessages: [Message]) {
        var merged = messages[chatId] ?? []
        merge(newMessages, into: &merged)
        messages[chatId] = merged
    }

    func addMessage(_ message: Message) {
        guard var list = messages[message.chatId] else { return }
        merge([message], into: &list)
        messages[message.chatId] = list
    }

    func replaceMessage(chatId: Int64, oldId: Int64, with message: Message) {
        guard var list = messages[chatId] else { return }
        list.removeAll { $0.id == oldId }
        merge([message], into: &list)
        messages[chatId] = list
    }

    func removeMessages(chatId: Int64, ids: [Int64]) {
        guard var list = messages[chatId] else { return }
        let set = Set(ids)
        list.removeAll { set.contains($0.id) }
        messages[chatId] = list
    }

    private func merge(_ newMessages: [Message], into list: inout [Message]) {
        guard !newMessages.isEmpty else { return }
        var byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in newMessages {
            byId[message.id] = message
        }
        list = byId.values.sorted { $0.id < $1.id }
    }

    // MARK: - Users & files

    func setUser(_ user: User) {
        users[user.id] = user
    }

    func updateFile(_ file: File) {
        files[file.id] = file
    }

    func latest(_ file: File) -> File {
        files[file.id] ?? file
    }

    /// Local path of the file if it has been fully downloaded.
    func localPath(_ file: File) -> String? {
        let file = latest(file)
        guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return nil }
        return file.local.path
    }

    // MARK: - Names

    func displayName(userId: Int64) -> String {
        guard let user = users[userId] else { return "…" }
        let name = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Удалённый аккаунт" : name
    }

    func senderName(_ sender: MessageSender) -> String {
        switch sender {
        case .messageSenderUser(let u): return displayName(userId: u.userId)
        case .messageSenderChat(let c): return chats[c.chatId]?.title ?? "Чат"
        }
    }
}
