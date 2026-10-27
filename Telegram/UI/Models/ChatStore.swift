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
    var notificationSettings: ChatNotificationSettings
    var blockList: BlockList?

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
        notificationSettings = chat.notificationSettings
        blockList = chat.blockList
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
    private static let localPinsKey = "localPinnedChatIds"

    private init() {
        let stored = UserDefaults.standard.array(forKey: Self.localPinsKey) as? [NSNumber] ?? []
        localPinnedChatIds = stored.map { $0.int64Value }
    }

    @Published private(set) var chats: [Int64: ChatItem] = [:]
    /// Chats pinned locally on top of the server limit, in display order.
    @Published private(set) var localPinnedChatIds: [Int64] = []
    /// Users blocked in the main block list; their messages are hidden everywhere.
    @Published private(set) var blockedUserIds: Set<Int64> = []
    /// Chat opened most recently; shown temporarily at the top of the list.
    @Published private(set) var lastOpenedChatId: Int64?
    /// Chats of the main list, sorted the same way as in official clients.
    @Published private(set) var mainChatIds: [Int64] = []
    /// chatId → messages sorted from oldest to newest.
    @Published private(set) var messages: [Int64: [Message]] = [:]
    /// Messages outside of the loaded history (e.g. replied-to messages).
    @Published private(set) var detachedMessages: [MessageKey: Message] = [:]
    /// chatId → pinned messages, newest first.
    @Published private(set) var pinnedByChat: [Int64: [Message]] = [:]
    @Published private(set) var users: [Int64: User] = [:]
    /// My membership status in supergroups/channels and basic groups.
    @Published private(set) var supergroupStatuses: [Int64: ChatMemberStatus] = [:]
    @Published private(set) var basicGroupStatuses: [Int64: ChatMemberStatus] = [:]
    @Published private(set) var userStatuses: [Int64: UserStatus] = [:]
    /// chatId → who is doing what right now ("typing", "recording voice"...).
    @Published private(set) var chatActions: [Int64: [MessageSender: ChatAction]] = [:]

    @Published var loadingChats: Set<Int64> = []
    /// Chats whose history has been loaded up to the very first message.
    @Published var fullyLoadedChats: Set<Int64> = []

    private var reorderWorkItem: DispatchWorkItem?

    /// Coalesces many position updates (mass channel refreshes) into one sort
    /// per runloop tick instead of one sort per update.
    func scheduleReorder() {
        reorderWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reorderWorkItem = nil
            self?.recomputeOrder()
        }
        reorderWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func removeChat(_ chatId: Int64) {
        chats.removeValue(forKey: chatId)
        mainChatIds.removeAll { $0 == chatId }
        messages.removeValue(forKey: chatId)
        pinnedByChat.removeValue(forKey: chatId)
        localPinnedChatIds.removeAll { $0 == chatId }
        if lastOpenedChatId == chatId { lastOpenedChatId = nil }
        chatActions.removeValue(forKey: chatId)
    }

    func reset() {
        chats = [:]
        mainChatIds = []
        messages = [:]
        detachedMessages = [:]
        pinnedByChat = [:]
        users = [:]
        supergroupStatuses = [:]
        basicGroupStatuses = [:]
        userStatuses = [:]
        chatActions = [:]
        blockedUserIds = []
        lastOpenedChatId = nil
        FileStore.shared.reset()
        FileUpdateCoalescer.shared.reset()
        loadingChats = []
        fullyLoadedChats = []
    }

    func clearLoadedMessages() {
        messages = [:]
        detachedMessages = [:]
        pinnedByChat = [:]
        fullyLoadedChats = []
    }

    // MARK: - Chats

    private var pendingChatUpdates: [Int64: [(inout ChatItem) -> Void]] = [:]
    private var pendingReorder = false
    private var chatUpdateWork: DispatchWorkItem?

    /// Coalesces hot per-message chat updates (last message, unread, positions)
    /// into one publish + one sort per runloop tick.
    func enqueueChatUpdate(_ chatId: Int64, reorder: Bool = false, _ change: @escaping (inout ChatItem) -> Void) {
        pendingChatUpdates[chatId, default: []].append(change)
        if reorder { pendingReorder = true }
        if chatUpdateWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.flushChatUpdates() }
            chatUpdateWork = work
            DispatchQueue.main.async(execute: work)
        }
    }

    private func flushChatUpdates() {
        chatUpdateWork = nil
        let updates = pendingChatUpdates
        pendingChatUpdates = [:]
        let reorder = pendingReorder
        pendingReorder = false
        guard !updates.isEmpty else { return }
        var updated = chats
        for (chatId, changes) in updates {
            guard var chat = updated[chatId] else { continue }
            for change in changes { change(&chat) }
            updated[chatId] = chat
        }
        chats = updated
        if reorder { recomputeOrder() }
    }

    private var pendingNewChats: [Chat] = []
    private var chatFlushWork: DispatchWorkItem?

    /// Batches updateNewChat bursts into ONE publish + ONE sort per runloop
    /// tick. Per-chat publishing/sorting during mass updates blocked the main
    /// thread for seconds (heartbeat showed mainAge 5–16s).
    func enqueueChat(_ chat: Chat) {
        pendingNewChats.append(chat)
        if chatFlushWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.flushNewChats() }
            chatFlushWork = work
            DispatchQueue.main.async(execute: work)
        }
    }

    /// Compatibility wrapper: immediate callers now also go through the batch.
    func addChat(_ chat: Chat) {
        enqueueChat(chat)
    }

    private func flushNewChats() {
        chatFlushWork = nil
        let incoming = pendingNewChats
        pendingNewChats = []
        guard !incoming.isEmpty else { return }
        var updated = chats
        for chat in incoming {
            updated[chat.id] = ChatItem(chat)
        }
        chats = updated
        recomputeOrder()
    }

    func updateChat(_ chatId: Int64, reorder: Bool = false, _ change: (inout ChatItem) -> Void) {
        guard var chat = chats[chatId] else { return }
        change(&chat)
        chats[chatId] = chat
        if reorder { scheduleReorder() }
    }

    func setPosition(chatId: Int64, position: ChatPosition) {
        updateChat(chatId, reorder: true) { chat in
            chat.positions.removeAll { $0.list == position.list }
            if position.order.rawValue != 0 {
                chat.positions.append(position)
            }
        }
    }

    /// Optimistic pin update; TDLib sends the authoritative position right after.
    func setPinned(chatId: Int64, isPinned: Bool) {
        updateChat(chatId, reorder: true) { chat in
            guard let index = chat.positions.firstIndex(where: { $0.list == .chatListMain }) else { return }
            let position = chat.positions[index]
            chat.positions[index] = ChatPosition(
                isPinned: isPinned,
                list: position.list,
                order: position.order,
                source: position.source
            )
        }
    }

    func isLocallyPinned(_ chatId: Int64) -> Bool {
        localPinnedChatIds.contains(chatId)
    }

    func setLastOpenedChat(_ chatId: Int64) {
        guard lastOpenedChatId != chatId else { return }
        lastOpenedChatId = chatId
    }

    func clearLastOpenedChat() {
        lastOpenedChatId = nil
    }

    func isUserBlocked(_ userId: Int64) -> Bool {
        blockedUserIds.contains(userId)
    }

    func setUserBlocked(_ userId: Int64, isBlocked: Bool) {
        var ids = blockedUserIds
        if isBlocked { ids.insert(userId) } else { ids.remove(userId) }
        guard ids != blockedUserIds else { return }
        blockedUserIds = ids
    }

    func setBlockedUsers(_ ids: Set<Int64>) {
        blockedUserIds = ids
    }

    func isSenderBlocked(_ sender: MessageSender) -> Bool {
        if case .messageSenderUser(let user) = sender {
            return blockedUserIds.contains(user.userId)
        }
        return false
    }

    /// Local pins are not restricted by Telegram's server-side pin limit.
    func setLocallyPinned(chatId: Int64, isPinned: Bool) {
        var ids = localPinnedChatIds
        ids.removeAll { $0 == chatId }
        if isPinned {
            ids.insert(chatId, at: 0)
        }
        guard ids != localPinnedChatIds else { return }
        localPinnedChatIds = ids
        UserDefaults.standard.set(ids.map { NSNumber(value: $0) }, forKey: Self.localPinsKey)
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

    /// Merges archived deleted messages into loaded history when the user has
    /// enabled "show deleted messages".
    func applyDeletedArchive(chatId: Int64) {
        guard PrivacyPreferences.shared.keepDeletedMessages else { return }
        let archived = DeletedMessageStore.shared.messages(chatId: chatId)
        guard !archived.isEmpty else { return }
        var list = messages[chatId] ?? []
        let ids = Set(list.map { $0.id })
        list.append(contentsOf: archived.filter { !ids.contains($0.id) })
        list.sort { $0.id < $1.id }
        messages[chatId] = list
    }

    func hideDeletedArchive() {
        for chatId in messages.keys {
            let archivedIds = Set(DeletedMessageStore.shared.messages(chatId: chatId).map { $0.id })
            guard !archivedIds.isEmpty else { continue }
            messages[chatId]?.removeAll { archivedIds.contains($0.id) }
        }
    }

    func applyDeletedArchiveEverywhere() {
        guard PrivacyPreferences.shared.keepDeletedMessages else { return }
        for chatId in messages.keys {
            applyDeletedArchive(chatId: chatId)
        }
    }

    func removeMessages(chatId: Int64, ids: [Int64]) {
        let set = Set(ids)
        for id in ids { detachedMessages[MessageKey(chatId: chatId, id: id)] = nil }
        if var pinned = pinnedByChat[chatId] {
            pinned.removeAll { set.contains($0.id) }
            pinnedByChat[chatId] = pinned.isEmpty ? nil : pinned
        }
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

    // MARK: - Pinned messages

    func pinnedMessages(chatId: Int64) -> [Message] {
        pinnedByChat[chatId] ?? []
    }

    func isMessagePinned(chatId: Int64, id: Int64) -> Bool {
        pinnedByChat[chatId]?.contains(where: { $0.id == id }) == true
    }

    func replacePinnedMessage(_ message: Message, chatId: Int64) {
        guard var list = pinnedByChat[chatId] else { return }
        if let index = list.firstIndex(where: { $0.id == message.id }) {
            list[index] = message
            pinnedByChat[chatId] = list
            detachedMessages[MessageKey(chatId: chatId, id: message.id)] = message
        }
    }

    func setPinnedMessages(_ newMessages: [Message], chatId: Int64) {
        pinnedByChat[chatId] = newMessages
        for message in newMessages {
            detachedMessages[MessageKey(chatId: chatId, id: message.id)] = message
        }
    }

    func addPinnedMessage(_ message: Message) {
        var list = pinnedByChat[message.chatId] ?? []
        list.removeAll { $0.id == message.id }
        list.insert(message, at: 0)
        pinnedByChat[message.chatId] = list
        detachedMessages[MessageKey(chatId: message.chatId, id: message.id)] = message
    }

    func removePinnedMessage(chatId: Int64, id: Int64) {
        guard var list = pinnedByChat[chatId] else { return }
        list.removeAll { $0.id == id }
        pinnedByChat[chatId] = list.isEmpty ? nil : list
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

    // MARK: - Names

    func displayName(userId: Int64) -> String {
        guard let user = users[userId] else { return "…" }
        let name = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Удалённый аккаунт" : name
    }

    func senderName(_ sender: MessageSender) -> String {
        switch sender {
        case .messageSenderUser(let u):
            return LocalAliases.shared.userAlias(u.userId) ?? displayName(userId: u.userId)
        case .messageSenderChat(let c):
            return LocalAliases.shared.chatAlias(c.chatId) ?? chats[c.chatId]?.title ?? "Чат"
        }
    }

    func originName(_ origin: MessageOrigin) -> String {
        switch origin {
        case .messageOriginUser(let o):
            return LocalAliases.shared.userAlias(o.senderUserId) ?? displayName(userId: o.senderUserId)
        case .messageOriginHiddenUser(let o):
            return o.senderName
        case .messageOriginChat(let o):
            return LocalAliases.shared.chatAlias(o.senderChatId) ?? chats[o.senderChatId]?.title ?? "Чат"
        case .messageOriginChannel(let o):
            return LocalAliases.shared.chatAlias(o.chatId) ?? chats[o.chatId]?.title ?? "Канал"
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

/// File metadata and download progress, isolated from chat/message updates.
/// Only media views observe it, so file progress never re-renders the whole chat list.
@MainActor
final class FileStore: ObservableObject {
    static let shared = FileStore()
    private init() {}

    private(set) var files: [Int: File] = [:]
    private var publishedProgress: [Int: Int64] = [:]
    private var lastPublish = Date.distantPast
    private var samples: [Int: (bytes: Int64, time: Foundation.Date)] = [:]
    private var speeds: [Int: Double] = [:]

    func reset() {
        files = [:]
        publishedProgress = [:]
        lastPublish = .distantPast
        samples = [:]
        speeds = [:]
    }

    func update(_ file: File) {
        let old = files[file.id]
        files[file.id] = file

        let total = max(file.size, file.expectedSize, 1)
        let progress = file.local.downloadedSize + file.remote.uploadedSize

        if file.local.isDownloadingActive {
            let now = Foundation.Date()
            if let previous = samples[file.id], now.timeIntervalSince(previous.time) >= 0.25 {
                let delta = Double(max(0, file.local.downloadedSize - previous.bytes))
                let instant = delta / now.timeIntervalSince(previous.time)
                if instant > 0 {
                    speeds[file.id] = speeds[file.id].map { $0 * 0.7 + instant * 0.3 } ?? instant
                }
            }
            samples[file.id] = (file.local.downloadedSize, now)
        } else {
            samples[file.id] = nil
            speeds[file.id] = nil
        }

        guard let old else {
            publishedProgress[file.id] = progress
            objectWillChange.send()
            return
        }

        let structuralChange = old.local.isDownloadingCompleted != file.local.isDownloadingCompleted
            || old.local.isDownloadingActive != file.local.isDownloadingActive
            || old.remote.isUploadingCompleted != file.remote.isUploadingCompleted
            || old.remote.isUploadingActive != file.remote.isUploadingActive
            || old.local.path != file.local.path

        if structuralChange {
            publishedProgress[file.id] = progress
            objectWillChange.send()
            return
        }

        // Smooth progress is coalesced into ~10% steps and at most ~10 UI updates per second.
        guard abs(progress - (publishedProgress[file.id] ?? 0)) * 10 >= total else { return }
        publishedProgress[file.id] = progress
        let now = Foundation.Date()
        guard now.timeIntervalSince(lastPublish) >= 0.1 else { return }
        lastPublish = now
        objectWillChange.send()
    }

    func latest(_ file: File) -> File {
        files[file.id] ?? file
    }

    /// Local path of the file if it has been fully downloaded.
    func remove(fileId: Int) {
        files[fileId] = nil
        samples[fileId] = nil
        speeds[fileId] = nil
        objectWillChange.send()
    }

    func localPath(_ file: File) -> String? {
        let file = latest(file)
        guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else { return nil }
        return file.local.path
    }

    struct DownloadStatus {
        let downloaded: Int64
        let total: Int64
        let fraction: Double
        let remainingBytes: Int64
        let remainingSeconds: TimeInterval?
    }

    func downloadStatus(_ file: File) -> DownloadStatus? {
        let file = latest(file)
        guard file.local.isDownloadingActive else { return nil }
        let total = max(file.size, file.expectedSize, 1)
        let downloaded = min(max(file.local.downloadedSize, 0), total)
        let remaining = max(0, total - downloaded)
        let speed = speeds[file.id] ?? 0
        return DownloadStatus(
            downloaded: downloaded,
            total: total,
            fraction: Double(downloaded) / Double(total),
            remainingBytes: remaining,
            remainingSeconds: speed > 1 ? Double(remaining) / speed : nil
        )
    }

    var downloadedFiles: [File] {
        files.values
            .filter {
                $0.local.isDownloadingCompleted &&
                !$0.local.path.isEmpty &&
                max($0.size, $0.expectedSize) > 0
            }
            .sorted {
                URL(fileURLWithPath: $0.local.path).lastPathComponent
                    .localizedCaseInsensitiveCompare(URL(fileURLWithPath: $1.local.path).lastPathComponent) == .orderedAscending
            }
    }

    /// Download or upload progress in 0...1, nil when idle.
    func progress(_ file: File) -> Double? {
        let file = latest(file)
        let total = Double(max(file.size, file.expectedSize, 1))
        if file.remote.isUploadingActive { return Double(file.remote.uploadedSize) / total }
        if file.local.isDownloadingActive { return Double(file.local.downloadedSize) / total }
        return nil
    }
}

/// Coalesces TDLib `updateFile` bursts (many per second during downloads) into
/// ~10 main-thread batches per second. This keeps scrolling free of update storms.
final class FileUpdateCoalescer: @unchecked Sendable {
    static let shared = FileUpdateCoalescer()

    private let lock = NSLock()
    private var pending: [Int: File] = [:]
    private var flushScheduled = false

    private init() {}

    func reset() {
        lock.lock()
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
    }

    func submit(_ file: File) {
        lock.lock()
        pending[file.id] = file
        let needsSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()

        guard !batch.isEmpty else { return }
        DispatchQueue.main.async {
            for file in batch.values {
                FileStore.shared.update(file)
            }
        }
    }
}

/// User-configurable rendering limits. History stays loaded; only the window
/// of rendered rows is bounded, so scrolling remains fast on large chats.
@MainActor
final class DisplayLimits: ObservableObject {
    static let shared = DisplayLimits()

    private enum Keys {
        static let messages = "displayLimitMessagesPerChat"
        static let chats = "displayLimitRenderedChats"
    }

    static let messageRange = 20...2000
    static let chatRange = 10...500

    @Published var maxMessagesPerChat: Int {
        didSet { UserDefaults.standard.set(maxMessagesPerChat, forKey: Keys.messages) }
    }

    @Published var maxRenderedChats: Int {
        didSet { UserDefaults.standard.set(maxRenderedChats, forKey: Keys.chats) }
    }

    private init() {
        let storedMessages = UserDefaults.standard.integer(forKey: Keys.messages)
        let storedChats = UserDefaults.standard.integer(forKey: Keys.chats)
        let device = DeviceProfiles.current
        let messages = storedMessages > 0 ? storedMessages : device.tier.recommendedMessages
        let chats = storedChats > 0 ? storedChats : device.tier.recommendedChats
        maxMessagesPerChat = min(max(messages, Self.messageRange.lowerBound), Self.messageRange.upperBound)
        maxRenderedChats = min(max(chats, Self.chatRange.lowerBound), Self.chatRange.upperBound)
    }

    var effectiveMessagesPerChat: Int {
        if UltraMode.shared.isEnabled { return 35 }
        let mode = PerformanceMode.shared
        if mode.isEnabled { return min(maxMessagesPerChat, mode.level.maxMessages) }
        if DevicePerformance.isLowMemory {
            return min(maxMessagesPerChat, DeviceProfiles.current.tier.recommendedMessages)
        }
        return maxMessagesPerChat
    }

    var effectiveRenderedChats: Int {
        if UltraMode.shared.isEnabled { return 20 }
        let mode = PerformanceMode.shared
        if mode.isEnabled { return min(maxRenderedChats, mode.level.maxChats) }
        if DevicePerformance.isLowMemory {
            return min(maxRenderedChats, DeviceProfiles.current.tier.recommendedChats)
        }
        return maxRenderedChats
    }

    func reset() {
        maxMessagesPerChat = 200
        maxRenderedChats = 100
    }
}

/// Case/diacritic-insensitive token search used by the chat list and contacts.
enum SearchMatcher {
    static func normalized(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Every query token must match the beginning of some target token (or
    /// occur inside it for longer queries), so word order and punctuation don't matter.
    static func matches(_ value: String, query: String) -> Bool {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return true }
        let targetTokens = normalized(value).split(separator: " ")
        return normalizedQuery.split(separator: " ").allSatisfy { queryToken in
            targetTokens.contains { targetToken in
                targetToken.hasPrefix(queryToken) ||
                    (queryToken.count >= 3 && targetToken.contains(queryToken))
            }
        }
    }

    static func score(_ value: String, query: String) -> Int {
        let target = normalized(value)
        let normalizedQuery = normalized(query)
        if target == normalizedQuery { return 0 }
        if target.hasPrefix(normalizedQuery) { return 1 }
        if target.contains(normalizedQuery) { return 2 }
        return 3
    }
}
