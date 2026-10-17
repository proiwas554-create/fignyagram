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
    var permissions: ChatPermissions
    var availableReactions: ChatAvailableReactions

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
        permissions = chat.permissions
        availableReactions = chat.availableReactions
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

struct MessageKey: Hashable {
    let chatId: Int64
    let id: Int64
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
    /// Messages outside of the loaded history (e.g. replied-to messages).
    @Published private(set) var detachedMessages: [MessageKey: Message] = [:]
    @Published private(set) var users: [Int64: User] = [:]
    /// My membership status in supergroups/channels and basic groups.
    @Published private(set) var supergroupStatuses: [Int64: ChatMemberStatus] = [:]
    @Published private(set) var basicGroupStatuses: [Int64: ChatMemberStatus] = [:]
    @Published private(set) var userStatuses: [Int64: UserStatus] = [:]
    /// chatId → who is doing what right now ("typing", "recording voice"...).
    @Published private(set) var chatActions: [Int64: [MessageSender: ChatAction]] = [:]

    /// Files change very often while downloading, so views are only refreshed on meaningful progress.
    private(set) var files: [Int: File] = [:]
    private var publishedProgress: [Int: Int64] = [:]

    @Published var loadingChats: Set<Int64> = []
    /// Chats whose history has been loaded up to the very first message.
    @Published var fullyLoadedChats: Set<Int64> = []

    func reset() {
        chats = [:]
        mainChatIds = []
        messages = [:]
        detachedMessages = [:]
        users = [:]
        supergroupStatuses = [:]
        basicGroupStatuses = [:]
        userStatuses = [:]
        chatActions = [:]
        files = [:]
        publishedProgress = [:]
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

    func setChatAction(chatId: Int64, sender: MessageSender, action: ChatAction) {
        var actions = chatActions[chatId] ?? [:]
        if case .chatActionCancel = action {
            guard actions.removeValue(forKey: sender) != nil else { return }
        } else {
            actions[sender] = action
        }
        chatActions[chatId] = actions.isEmpty ? nil : actions
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
        let key = MessageKey(chatId: chatId, id: oldId)
        if detachedMessages[key] != nil {
            detachedMessages[key] = nil
            detachedMessages[MessageKey(chatId: chatId, id: message.id)] = message
        }
        guard var list = messages[chatId] else { return }
        if oldId == message.id, let index = index(of: oldId, in: list) {
            list[index] = message
        } else {
            list.removeAll { $0.id == oldId }
            merge([message], into: &list)
        }
        messages[chatId] = list
    }

    func removeMessages(chatId: Int64, ids: [Int64]) {
        let set = Set(ids)
        for id in ids { detachedMessages[MessageKey(chatId: chatId, id: id)] = nil }
        guard var list = messages[chatId] else { return }
        list.removeAll { set.contains($0.id) }
        messages[chatId] = list
    }

    func storeDetached(_ message: Message) {
        detachedMessages[MessageKey(chatId: message.chatId, id: message.id)] = message
    }

    func message(chatId: Int64, id: Int64) -> Message? {
        if let list = messages[chatId], let index = index(of: id, in: list) { return list[index] }
        return detachedMessages[MessageKey(chatId: chatId, id: id)]
    }

    /// Binary search: message lists are always sorted by id.
    private func index(of id: Int64, in list: [Message]) -> Int? {
        var low = 0
        var high = list.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if list[mid].id == id { return mid }
            if list[mid].id < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    private func merge(_ newMessages: [Message], into list: inout [Message]) {
        guard !newMessages.isEmpty else { return }
        // Fast path for the common case: a single new message at the end.
        if newMessages.count == 1, let message = newMessages.first {
            if let last = list.last, message.id > last.id {
                list.append(message)
                return
            }
            if let index = index(of: message.id, in: list) {
                list[index] = message
                return
            }
        }
        var byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in newMessages {
            byId[message.id] = message
        }
        list = byId.values.sorted { $0.id < $1.id }
    }

    // MARK: - Users & files

    func setUser(_ user: User) {
        users[user.id] = user
        userStatuses[user.id] = user.status
    }

    func setSupergroupStatus(id: Int64, status: ChatMemberStatus) {
        supergroupStatuses[id] = status
    }

    func setBasicGroupStatus(id: Int64, status: ChatMemberStatus) {
        basicGroupStatuses[id] = status
    }

    /// Whether I can post in the chat: owners/admins with posting rights in channels,
    /// non-restricted members in groups, everyone in private chats.
    func canWrite(chatId: Int64) -> Bool {
        guard let chat = chats[chatId] else { return false }
        switch chat.type {
        case .chatTypePrivate, .chatTypeSecret:
            return true
        case .chatTypeBasicGroup(let g):
            return Self.canWrite(status: basicGroupStatuses[g.basicGroupId], isChannel: false, permissions: chat.permissions)
        case .chatTypeSupergroup(let s):
            return Self.canWrite(status: supergroupStatuses[s.supergroupId], isChannel: s.isChannel, permissions: chat.permissions)
        }
    }

    private static func canWrite(status: ChatMemberStatus?, isChannel: Bool, permissions: ChatPermissions) -> Bool {
        switch status {
        case .chatMemberStatusCreator:
            return true
        case .chatMemberStatusAdministrator(let admin):
            return !isChannel || admin.rights.canPostMessages
        case .chatMemberStatusMember:
            return !isChannel && permissions.canSendBasicMessages
        case .chatMemberStatusRestricted(let r):
            return !isChannel && r.isMember && r.permissions.canSendBasicMessages
        case .chatMemberStatusLeft, .chatMemberStatusBanned:
            return false
        case nil:
            // Status not known yet: allow in groups, TDLib will report an error if posting is forbidden.
            return !isChannel
        }
    }

    func setUserStatus(userId: Int64, status: UserStatus) {
        userStatuses[userId] = status
    }

    func updateFile(_ file: File) {
        let old = files[file.id]
        files[file.id] = file
        if shouldPublish(old: old, new: file) {
            publishedProgress[file.id] = file.local.downloadedSize + file.remote.uploadedSize
            objectWillChange.send()
        }
    }

    private func shouldPublish(old: File?, new: File) -> Bool {
        guard let old else { return true }
        if old.local.isDownloadingCompleted != new.local.isDownloadingCompleted
            || old.local.isDownloadingActive != new.local.isDownloadingActive
            || old.remote.isUploadingCompleted != new.remote.isUploadingCompleted
            || old.remote.isUploadingActive != new.remote.isUploadingActive
            || old.local.path != new.local.path {
            return true
        }
        let total = max(new.size, new.expectedSize, 1)
        let progress = new.local.downloadedSize + new.remote.uploadedSize
        return abs(progress - (publishedProgress[new.id] ?? 0)) * 20 >= total
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

    /// Download or upload progress in 0...1, nil when idle.
    func progress(_ file: File) -> Double? {
        let file = latest(file)
        let total = Double(max(file.size, file.expectedSize, 1))
        if file.remote.isUploadingActive { return Double(file.remote.uploadedSize) / total }
        if file.local.isDownloadingActive { return Double(file.local.downloadedSize) / total }
        return nil
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

    func originName(_ origin: MessageOrigin) -> String {
        switch origin {
        case .messageOriginUser(let o): return displayName(userId: o.senderUserId)
        case .messageOriginHiddenUser(let o): return o.senderName
        case .messageOriginChat(let o): return chats[o.senderChatId]?.title ?? "Чат"
        case .messageOriginChannel(let o): return chats[o.chatId]?.title ?? "Канал"
        }
    }

    /// "Вася печатает…" style text, nil when nobody is doing anything.
    func actionText(chatId: Int64) -> String? {
        guard let actions = chatActions[chatId], let (sender, action) = actions.first else { return nil }
        let verb = MessageFormatter.actionVerb(action)
        let chat = chats[chatId]
        if chat?.privateUserId != nil || actions.count == 1 && chat?.isGroup != true {
            return verb
        }
        let name = senderName(sender).split(separator: " ").first.map(String.init) ?? ""
        return actions.count > 1 ? "\(name) и ещё \(actions.count - 1) \(verb)" : "\(name) \(verb)"
    }
}
