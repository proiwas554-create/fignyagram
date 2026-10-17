import Foundation
import Combine
import TDLibKit
import UIKit

enum AuthStep: Equatable {
    case initializing
    case phone
    case code(AuthenticationCodeInfo)
    case emailAddress
    case emailCode(EmailAddressAuthenticationCodeInfo)
    case registration
    case password(hint: String)
    case qrCode(link: String)
    case premiumRequired
    case ready
    case loggingOut
}

@MainActor
final class TelegramClient: ObservableObject {

    static let shared = TelegramClient()
    private init() {}

    private var manager: TDLibClientManager?
    private var client: TDLibClient?
    private let store = ChatStore.shared

    @Published private(set) var authStep: AuthStep = .initializing
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var me: User?
    @Published private(set) var isLoadingChats = false
    @Published private(set) var allChatsLoaded = false

    var isAuthorized: Bool { authStep == .ready }

    private var openedChatId: Int64?
    private var requestedDownloads: Set<Int> = []
    private var requestedMessages: Set<MessageKey> = []
    private var lastTypingSent: [Int64: Foundation.Date] = [:]

    // MARK: - Lifecycle

    func start() {
        guard client == nil else { return }
        if manager == nil {
            manager = TDLibClientManager()
        }
        guard let manager else { return }
        let newClient = manager.createClient(updateHandler: Self.makeUpdateHandler())
        _ = try? newClient.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
        client = newClient
    }

    /// Updates are decoded on TDLib's serial queue and delivered to the main thread in order.
    nonisolated private static func makeUpdateHandler() -> (Data, TDLibClient) -> Void {
        return { data, client in
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            let clientId = client.id
            DispatchQueue.main.async {
                TelegramClient.shared.handle(update, clientId: clientId)
            }
        }
    }

    private func sendTdlibParameters() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "ru"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        perform { client in
            try await client.setTdlibParameters(
                apiHash: Secrets.apiHash,
                apiId: Secrets.apiId,
                applicationVersion: "Fignyagram \(version)",
                databaseDirectory: docs + "/tdlib_db",
                databaseEncryptionKey: nil,
                deviceModel: UIDevice.current.model,
                filesDirectory: docs + "/tdlib_files",
                systemLanguageCode: language,
                systemVersion: UIDevice.current.systemVersion,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: false,
                useTestDc: false
            )
        }
    }

    /// Runs a TDLib request, tracking the busy state and showing errors in the UI.
    private func perform(_ action: @escaping (TDLibClient) async throws -> Void) {
        guard let client else { return }
        isBusy = true
        errorMessage = nil
        Task {
            do {
                try await action(client)
            } catch {
                self.errorMessage = Self.describe(error)
            }
            self.isBusy = false
        }
    }

    static func describe(_ error: Swift.Error) -> String {
        guard let tdError = error as? TDLibKit.Error else { return error.localizedDescription }
        let message = tdError.message
        if message.hasPrefix("Too Many Requests") || message.hasPrefix("FLOOD_WAIT") {
            let seconds = message.split(separator: " ").last.flatMap { Int($0) }
            return seconds.map { "Слишком много попыток. Повторите через \($0) с." } ?? "Слишком много попыток. Попробуйте позже."
        }
        switch message {
        case "PHONE_NUMBER_INVALID": return "Неверный номер телефона"
        case "PHONE_NUMBER_BANNED": return "Этот номер заблокирован в Telegram"
        case "PHONE_CODE_INVALID": return "Неверный код"
        case "PHONE_CODE_EXPIRED": return "Срок действия кода истёк, запросите новый"
        case "PHONE_CODE_EMPTY": return "Введите код"
        case "PASSWORD_HASH_INVALID": return "Неверный пароль"
        case "EMAIL_CODE_INVALID": return "Неверный код из письма"
        case "EMAIL_INVALID": return "Неверный email"
        case "FIRSTNAME_INVALID": return "Неверное имя"
        case "API_ID_INVALID", "API_ID_PUBLISHED_FLOOD": return "Неверные api_id / api_hash в Secrets.swift"
        case "CHAT_WRITE_FORBIDDEN", "Have no write access to the chat": return "Нет прав писать в этот чат"
        default: return message
        }
    }

    // MARK: - Updates

    private func handle(_ update: Update, clientId: Int32) {
        guard clientId == client?.id else { return }

        switch update {
        case .updateAuthorizationState(let u):
            handleAuthState(u.authorizationState)

        case .updateNewChat(let u):
            store.addChat(u.chat)
        case .updateChatTitle(let u):
            store.updateChat(u.chatId) { $0.title = u.title }
        case .updateChatPhoto(let u):
            store.updateChat(u.chatId) { $0.photo = u.photo }
        case .updateChatLastMessage(let u):
            store.updateChat(u.chatId, reorder: true) {
                $0.lastMessage = u.lastMessage
                $0.positions = u.positions
            }
        case .updateChatDraftMessage(let u):
            store.updateChat(u.chatId, reorder: true) { $0.positions = u.positions }
        case .updateChatPosition(let u):
            store.setPosition(chatId: u.chatId, position: u.position)
        case .updateChatReadInbox(let u):
            store.updateChat(u.chatId) {
                $0.unreadCount = u.unreadCount
                $0.lastReadInboxMessageId = u.lastReadInboxMessageId
            }
        case .updateChatReadOutbox(let u):
            store.updateChat(u.chatId) { $0.lastReadOutboxMessageId = u.lastReadOutboxMessageId }
        case .updateChatIsMarkedAsUnread(let u):
            store.updateChat(u.chatId) { $0.isMarkedAsUnread = u.isMarkedAsUnread }
        case .updateChatPermissions(let u):
            store.updateChat(u.chatId) { $0.permissions = u.permissions }
        case .updateChatAvailableReactions(let u):
            store.updateChat(u.chatId) { $0.availableReactions = u.availableReactions }
        case .updateChatAction(let u):
            if u.senderId != me.map({ .messageSenderUser(MessageSenderUser(userId: $0.id)) }) {
                store.setChatAction(chatId: u.chatId, sender: u.senderId, action: u.action)
            }

        case .updateNewMessage(let u):
            store.addMessage(u.message)
            if u.message.chatId == openedChatId, !u.message.isOutgoing {
                markAsRead(chatId: u.message.chatId, messageIds: [u.message.id])
            }
        case .updateMessageSendSucceeded(let u):
            store.replaceMessage(chatId: u.message.chatId, oldId: u.oldMessageId, with: u.message)
        case .updateMessageSendFailed(let u):
            store.replaceMessage(chatId: u.message.chatId, oldId: u.oldMessageId, with: u.message)
            errorMessage = "Не удалось отправить: \(Self.describe(u.error))"
        case .updateMessageContent(let u):
            refreshMessage(chatId: u.chatId, messageId: u.messageId)
        case .updateMessageEdited(let u):
            refreshMessage(chatId: u.chatId, messageId: u.messageId)
        case .updateMessageInteractionInfo(let u):
            refreshMessage(chatId: u.chatId, messageId: u.messageId)
        case .updateDeleteMessages(let u):
            if u.isPermanent {
                store.removeMessages(chatId: u.chatId, ids: u.messageIds)
            }

        case .updateUser(let u):
            store.setUser(u.user)
            if u.user.id == me?.id { me = u.user }
        case .updateSupergroup(let u):
            store.setSupergroupStatus(id: u.supergroup.id, status: u.supergroup.status)
        case .updateBasicGroup(let u):
            store.setBasicGroupStatus(id: u.basicGroup.id, status: u.basicGroup.status)
        case .updateUserStatus(let u):
            store.setUserStatus(userId: u.userId, status: u.status)
        case .updateFile(let u):
            store.updateFile(u.file)

        default:
            break
        }
    }

    private func handleAuthState(_ state: AuthorizationState) {
        isBusy = false
        errorMessage = nil
        switch state {
        case .authorizationStateWaitTdlibParameters:
            authStep = .initializing
            sendTdlibParameters()
        case .authorizationStateWaitPhoneNumber:
            authStep = .phone
        case .authorizationStateWaitCode(let s):
            authStep = .code(s.codeInfo)
        case .authorizationStateWaitEmailAddress:
            authStep = .emailAddress
        case .authorizationStateWaitEmailCode(let s):
            authStep = .emailCode(s.codeInfo)
        case .authorizationStateWaitRegistration:
            authStep = .registration
        case .authorizationStateWaitPassword(let s):
            authStep = .password(hint: s.passwordHint)
        case .authorizationStateWaitOtherDeviceConfirmation(let s):
            authStep = .qrCode(link: s.link)
        case .authorizationStateWaitPremiumPurchase:
            authStep = .premiumRequired
        case .authorizationStateReady:
            authStep = .ready
            onAuthorized()
        case .authorizationStateLoggingOut, .authorizationStateClosing:
            authStep = .loggingOut
        case .authorizationStateClosed:
            // Happens after logout: TDLib requires a brand new client instance.
            client = nil
            me = nil
            openedChatId = nil
            requestedDownloads = []
            requestedMessages = []
            lastTypingSent = [:]
            allChatsLoaded = false
            isLoadingChats = false
            store.reset()
            authStep = .initializing
            start()
        }
    }

    private func onAuthorized() {
        guard let client else { return }
        Task {
            if let user = try? await client.getMe() {
                self.me = user
                self.store.setUser(user)
            }
        }
        loadMoreChats()
        Self.cleanOutgoingDirectory()
        Task {
            // Keeps the TDLib cache small: drops files unused for 3 days and caps the total at 300 MB.
            _ = try? await client.optimizeStorage(
                chatIds: [], chatLimit: 100, count: -1, excludeChatIds: [], fileTypes: [],
                immunityDelay: -1, returnDeletedFileStatistics: false, size: 300 * 1024 * 1024, ttl: 3 * 24 * 3600
            )
        }
    }

    /// Tells Telegram whether the app is in the foreground; TDLib keeps fewer connections when offline.
    func setOnline(_ online: Bool) {
        guard let client, isAuthorized else { return }
        Task { _ = try? await client.setOption(name: "online", value: .optionValueBoolean(OptionValueBoolean(value: online))) }
    }

    // MARK: - Authorization

    func sendPhoneNumber(_ phone: String) {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { errorMessage = "Введите номер телефона"; return }
        perform { client in
            try await client.setAuthenticationPhoneNumber(
                phoneNumber: digits,
                settings: PhoneNumberAuthenticationSettings(
                    allowFlashCall: false, allowMissedCall: false, allowSmsRetrieverApi: false,
                    authenticationTokens: [], firebaseAuthenticationSettings: nil,
                    hasUnknownPhoneNumber: false, isCurrentPhoneNumber: false
                )
            )
        }
    }

    func requestQrCode() {
        perform { try await $0.requestQrCodeAuthentication(otherUserIds: []) }
    }

    func sendCode(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespaces)
        perform { try await $0.checkAuthenticationCode(code: code) }
    }

    func resendCode() {
        perform { try await $0.resendAuthenticationCode(reason: .resendCodeReasonUserRequest) }
    }

    func sendEmail(_ email: String) {
        let email = email.trimmingCharacters(in: .whitespaces)
        perform { try await $0.setAuthenticationEmailAddress(emailAddress: email) }
    }

    func sendEmailCode(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespaces)
        perform {
            try await $0.checkAuthenticationEmailCode(
                code: .emailAddressAuthenticationCode(EmailAddressAuthenticationCode(code: code))
            )
        }
    }

    func sendPassword(_ password: String) {
        perform { try await $0.checkAuthenticationPassword(password: password) }
    }

    func register(firstName: String, lastName: String) {
        let first = firstName.trimmingCharacters(in: .whitespaces)
        let last = lastName.trimmingCharacters(in: .whitespaces)
        perform { try await $0.registerUser(disableNotification: false, firstName: first, lastName: last) }
    }

    func logOut() {
        perform { try await $0.logOut() }
    }

    // MARK: - Chats

    func loadMoreChats() {
        guard let client, isAuthorized, !isLoadingChats, !allChatsLoaded else { return }
        isLoadingChats = true
        Task {
            do {
                try await client.loadChats(chatList: .chatListMain, limit: 50)
            } catch let error as TDLibKit.Error where error.code == 404 {
                self.allChatsLoaded = true
            } catch {
                self.errorMessage = Self.describe(error)
            }
            self.isLoadingChats = false
        }
    }

    // MARK: - Messages

    func openChat(_ chatId: Int64) {
        guard let client else { return }
        openedChatId = chatId
        Task { try? await client.openChat(chatId: chatId) }
        if store.isHistoryLoaded(chatId) {
            markAllAsRead(chatId: chatId)
        } else {
            loadHistory(chatId: chatId)
        }
    }

    func closeChat(_ chatId: Int64) {
        guard let client else { return }
        if openedChatId == chatId { openedChatId = nil }
        Task { try? await client.closeChat(chatId: chatId) }
    }

    /// Loads the newest messages of the chat.
    func loadHistory(chatId: Int64) {
        fetchHistory(chatId: chatId, fromMessageId: 0)
    }

    /// Loads messages older than the oldest one already loaded.
    func loadOlderMessages(chatId: Int64) {
        guard let oldest = store.messages[chatId]?.first?.id else { return }
        fetchHistory(chatId: chatId, fromMessageId: oldest)
    }

    private func fetchHistory(chatId: Int64, fromMessageId: Int64) {
        guard let client,
              !store.loadingChats.contains(chatId),
              !store.fullyLoadedChats.contains(chatId) else { return }
        store.loadingChats.insert(chatId)
        Task {
            do {
                var collected: [Message] = []
                var fromId = fromMessageId
                var reachedStart = false
                // TDLib may return fewer messages than requested (e.g. only cached ones), so ask a few times.
                for _ in 0..<5 where collected.count < 30 && !reachedStart {
                    let batch = try await client.getChatHistory(
                        chatId: chatId, fromMessageId: fromId, limit: 50, offset: 0, onlyLocal: false
                    ).messages ?? []
                    let fresh = batch.filter { $0.id != fromId }
                    if fresh.isEmpty {
                        reachedStart = true
                    } else {
                        collected += fresh
                        fromId = fresh.map(\.id).min() ?? fromId
                    }
                }
                self.store.setHistory(chatId: chatId, messages: collected)
                if reachedStart {
                    self.store.fullyLoadedChats.insert(chatId)
                }
                if fromMessageId == 0 {
                    self.markAllAsRead(chatId: chatId)
                }
            } catch {
                self.errorMessage = Self.describe(error)
            }
            self.store.loadingChats.remove(chatId)
        }
    }

    private func refreshMessage(chatId: Int64, messageId: Int64) {
        guard let client, store.isHistoryLoaded(chatId) || store.message(chatId: chatId, id: messageId) != nil else { return }
        Task {
            if let message = try? await client.getMessage(chatId: chatId, messageId: messageId) {
                self.store.replaceMessage(chatId: chatId, oldId: messageId, with: message)
            }
        }
    }

    private func markAllAsRead(chatId: Int64) {
        let ids = (store.messages[chatId] ?? []).suffix(100).map(\.id)
        markAsRead(chatId: chatId, messageIds: ids)
    }

    private func markAsRead(chatId: Int64, messageIds: [Int64]) {
        guard let client, !messageIds.isEmpty else { return }
        Task {
            try? await client.viewMessages(chatId: chatId, forceRead: true, messageIds: messageIds, source: nil)
        }
    }

    // MARK: - Sending

    func send(_ content: InputMessageContent, to chatId: Int64, replyTo: Int64? = nil) {
        guard let client else { return }
        let reply = replyTo.map {
            InputMessageReplyTo.inputMessageReplyToMessage(
                InputMessageReplyToMessage(checklistTaskId: 0, messageId: $0, pollOptionId: "", quote: nil)
            )
        }
        lastTypingSent[chatId] = nil
        Task {
            do {
                _ = try await client.sendMessage(
                    chatId: chatId, inputMessageContent: content,
                    options: nil, replyMarkup: nil, replyTo: reply, topicId: nil
                )
            } catch {
                self.errorMessage = Self.describe(error)
            }
        }
    }

    static func formatted(_ text: String) -> FormattedText {
        FormattedText(entities: [], text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func captionText(_ text: String) -> FormattedText? {
        let caption = formatted(text)
        return caption.text.isEmpty ? nil : caption
    }

    private static func local(_ url: URL) -> InputFile {
        .inputFileLocal(InputFileLocal(path: url.path))
    }

    func sendText(_ text: String, to chatId: Int64, replyTo: Int64? = nil) {
        let formatted = Self.formatted(text)
        guard !formatted.text.isEmpty else { return }
        send(.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: formatted)), to: chatId, replyTo: replyTo)
    }

    func sendPhoto(_ url: URL, width: Int, height: Int, caption: String, to chatId: Int64, replyTo: Int64?) {
        let photo = InputPhoto(addedStickerFileIds: [], height: height, photo: Self.local(url), thumbnail: nil, video: nil, width: width)
        send(.inputMessagePhoto(InputMessagePhoto(
            caption: Self.captionText(caption), hasSpoiler: false, photo: photo,
            selfDestructType: nil, showCaptionAboveMedia: false
        )), to: chatId, replyTo: replyTo)
    }

    func sendVideo(_ url: URL, width: Int, height: Int, duration: Int, caption: String, to chatId: Int64, replyTo: Int64?) {
        let video = InputVideo(
            addedStickerFileIds: [], cover: nil, duration: duration, height: height, startTimestamp: 0,
            supportsStreaming: true, thumbnail: nil, video: Self.local(url), width: width
        )
        send(.inputMessageVideo(InputMessageVideo(
            caption: Self.captionText(caption), hasSpoiler: false, selfDestructType: nil,
            showCaptionAboveMedia: false, video: video
        )), to: chatId, replyTo: replyTo)
    }

    func sendDocument(_ url: URL, caption: String, to chatId: Int64, replyTo: Int64?) {
        let document = InputDocument(disableContentTypeDetection: false, document: Self.local(url), thumbnail: nil)
        send(.inputMessageDocument(InputMessageDocument(caption: Self.captionText(caption), document: document)), to: chatId, replyTo: replyTo)
    }

    func sendVoiceNote(_ url: URL, duration: Int, waveform: Data, to chatId: Int64, replyTo: Int64?) {
        let voice = InputVoiceNote(duration: duration, voiceNote: Self.local(url), waveform: waveform)
        send(.inputMessageVoiceNote(InputMessageVoiceNote(caption: nil, selfDestructType: nil, voiceNote: voice)), to: chatId, replyTo: replyTo)
    }

    func sendVideoNote(_ url: URL, duration: Int, length: Int, to chatId: Int64, replyTo: Int64?) {
        let note = InputVideoNote(duration: duration, length: length, thumbnail: nil, videoNote: Self.local(url))
        send(.inputMessageVideoNote(InputMessageVideoNote(selfDestructType: nil, videoNote: note)), to: chatId, replyTo: replyTo)
    }

    /// Directory for files prepared for upload; TDLib reads them until the upload completes.
    nonisolated static var outgoingDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func makeOutgoingURL(extension ext: String) -> URL {
        outgoingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private static func cleanOutgoingDirectory() {
        let fm = FileManager.default
        let dayAgo = Foundation.Date().addingTimeInterval(-24 * 3600)
        guard let files = try? fm.contentsOfDirectory(at: outgoingDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < dayAgo { try? fm.removeItem(at: file) }
        }
    }

    // MARK: - Message actions

    func editMessage(_ message: Message, text: String) {
        guard let client else { return }
        let formatted = Self.formatted(text)
        Task {
            do {
                if case .messageText = message.content {
                    guard !formatted.text.isEmpty else { return }
                    _ = try await client.editMessageText(
                        chatId: message.chatId,
                        inputMessageContent: .inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: formatted)),
                        messageId: message.id, replyMarkup: nil
                    )
                } else {
                    _ = try await client.editMessageCaption(
                        caption: formatted, chatId: message.chatId, messageId: message.id,
                        replyMarkup: nil, showCaptionAboveMedia: false
                    )
                }
            } catch {
                self.errorMessage = Self.describe(error)
            }
        }
    }

    func deleteMessages(chatId: Int64, ids: [Int64], forAll: Bool) {
        perform { try await $0.deleteMessages(chatId: chatId, messageIds: ids, revoke: forAll) }
    }

    func forward(_ message: Message, to chatId: Int64) {
        perform {
            _ = try await $0.forwardMessages(
                chatId: chatId, fromChatId: message.chatId, messageIds: [message.id],
                options: nil, removeCaption: false, sendCopy: false, topicId: nil
            )
        }
    }

    func properties(of message: Message) async -> MessageProperties? {
        try? await client?.getMessageProperties(chatId: message.chatId, messageId: message.id)
    }

    func availableReactions(for message: Message) async -> [ReactionType] {
        guard let result = try? await client?.getMessageAvailableReactions(chatId: message.chatId, messageId: message.id, rowSize: 8) else {
            return []
        }
        let isPremium = me?.isPremium ?? false
        var seen = Set<ReactionType>()
        return (result.topReactions + result.recentReactions + result.popularReactions)
            .filter { isPremium || !$0.needsPremium }
            .map(\.type)
            .filter { seen.insert($0).inserted }
    }

    func toggleReaction(_ type: ReactionType, on message: Message) {
        guard let client else { return }
        let chosen = message.interactionInfo?.reactions?.reactions.contains { $0.type == type && $0.isChosen } ?? false
        Task {
            do {
                if chosen {
                    _ = try await client.removeMessageReaction(chatId: message.chatId, messageId: message.id, reactionType: type)
                } else {
                    _ = try await client.addMessageReaction(
                        chatId: message.chatId, isBig: false, messageId: message.id,
                        reactionType: type, updateRecentReactions: true
                    )
                }
            } catch {
                self.errorMessage = Self.describe(error)
            }
        }
    }

    /// Loads a replied-to message that is not part of the loaded history.
    func loadMessage(chatId: Int64, id: Int64) {
        guard let client, store.message(chatId: chatId, id: id) == nil else { return }
        let key = MessageKey(chatId: chatId, id: id)
        guard !requestedMessages.contains(key) else { return }
        requestedMessages.insert(key)
        Task {
            if let message = try? await client.getMessage(chatId: chatId, messageId: id) {
                self.store.storeDetached(message)
            }
        }
    }

    /// Sends "typing…" (or another action) at most once every 4 seconds per chat.
    func sendChatAction(_ action: ChatAction, chatId: Int64) {
        guard let client else { return }
        let now = Foundation.Date()
        if case .chatActionCancel = action {
            lastTypingSent[chatId] = nil
        } else if let last = lastTypingSent[chatId], now.timeIntervalSince(last) < 4 {
            return
        } else {
            lastTypingSent[chatId] = now
        }
        Task { _ = try? await client.sendChatAction(action: action, businessConnectionId: nil, chatId: chatId, topicId: nil) }
    }

    // MARK: - Files

    func download(_ file: File, priority: Int = 1) {
        guard let client else { return }
        let current = store.latest(file)
        guard current.local.canBeDownloaded,
              !current.local.isDownloadingCompleted,
              !requestedDownloads.contains(file.id) else { return }
        requestedDownloads.insert(file.id)
        Task {
            if let updated = try? await client.downloadFile(
                fileId: file.id, limit: 0, offset: 0, priority: priority, synchronous: false
            ) {
                self.store.updateFile(updated)
            } else {
                self.requestedDownloads.remove(file.id)
            }
        }
    }
}
