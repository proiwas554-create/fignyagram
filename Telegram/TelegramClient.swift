import Foundation
import SwiftUI
import AVFoundation
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

/// Errors raised before a request even reaches TDLib.
enum ChatCreationError: LocalizedError {
    case notReady
    case emptyUsername

    var errorDescription: String? {
        switch self {
        case .notReady: return "Подключение к Telegram ещё не готово"
        case .emptyUsername: return "Введите имя пользователя"
        }
    }
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
    private var recentConnects: [Foundation.Date] = []
    @Published private(set) var me: User?
    @Published private(set) var isLoadingChats = false
    @Published private(set) var allChatsLoaded = false

    var isAuthorized: Bool { authStep == .ready }

    private var openedChatId: Int64?
    private var requestedDownloads: Set<Int> = []
    private(set) var activeDownloadCount = 0
    private var downloadBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var requestedMessages: Set<MessageKey> = []
    private var lastTypingSent: [Int64: Foundation.Date] = [:]
    private var protectedDataObserver: NSObjectProtocol?
    private var needsTdlibParameters = false
    private var parametersRetryTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func setLogVerbosity(_ level: Int) {
        guard let client else { return }
        Task { _ = try? await client.setLogVerbosityLevel(newVerbosityLevel: level) }
    }

    func start() {
        guard client == nil else { return }
        // On a cold launch from a locked device (background audio/notification)
        // the app container may be inaccessible until protected data is available.
        guard UIApplication.shared.isProtectedDataAvailable else {
            observeProtectedDataIfNeeded()
            return
        }
        if manager == nil {
            manager = TDLibClientManager()
        }
        guard let manager else { return }
        // Client creation + the initial sync execute() must not run on the main
        // thread: TDLibKit's sync bridge would stall the UI during startup.
        DispatchQueue.global(qos: .userInitiated).async {
            DiagnosticsLog.log("TDLib createClient begin")
        let newClient = manager.createClient(updateHandler: Self.makeUpdateHandler())
        DiagnosticsLog.log("TDLib createClient done id=\(newClient.id)")
            do {
                _ = try newClient.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
                DiagnosticsLog.log("TDLib verbosity 1 ok")
            } catch {
                DiagnosticsLog.log("TDLib verbosity FAILED \(error)")
            }
            // Keep TDLib's default stderr log stream: ConsoleCapture redirects
            // fd 2 to Documents/console.log. Installing a file log stream here
            // silenced TDLib's own output, which we need for the call actor.
            DispatchQueue.main.async {
                self.client = newClient
                // Re-attach the built-in proxy whenever a TDLib client is
                // (re)created, including phone-number and QR login flows.
                BuiltInProxyManager.shared.applyIfEnabled()
            }
        }
    }

    private func observeProtectedDataIfNeeded() {
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.protectedDataObserver = nil
                self?.start()
            }
        }
    }

    /// Updates are decoded on TDLib's serial queue and delivered to the main thread in order.
    nonisolated private static func makeUpdateHandler() -> (Data, TDLibClient) -> Void {
        return { data, client in
            let update: Update
            do {
                update = try client.decoder.decode(Update.self, from: data)
            } catch {
                // A dropped update here silently breaks features (e.g. a call
                // that never reaches callStateReady). Log the type and reason.
                var kind = "<undecodable>"
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = object["@type"] as? String {
                    kind = type
                }
                CallDiag.log("decode FAILED type=\(kind) bytes=\(data.count) error=\(String(describing: error).prefix(300))")
                if kind == "updateCall",
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        CallManager.shared.handleRawCallUpdate(object)
                    }
                }
                return
            }
            // File progress arrives in bursts; coalesce it before touching the main thread.
            if case .updateFile(let u) = update {
                FileUpdateCoalescer.shared.submit(u.file)
                return
            }
            let clientId = client.id
            DispatchQueue.main.async {
                TelegramClient.shared.handle(update, clientId: clientId)
            }
        }
    }

    private func sendTdlibParameters() {
        guard client != nil else { return }
        var account = AccountStore.shared.current
        if let error = Self.prepareDirectories(for: account) {
            errorMessage = "Не удалось подготовить хранилище: \(error)"
            scheduleParametersRetry()
            return
        }
        account = AccountStore.shared.current
        needsTdlibParameters = false
        parametersRetryTask?.cancel()
        parametersRetryTask = nil
        errorMessage = nil
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "ru"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        Task.detached(priority: .userInitiated) {
            // The proxy attaches itself asynchronously via BuiltInProxyManager;
            // the first TDLib call must never block the main thread.
            await MainActor.run {
                TelegramClient.shared.perform { client in
                try await client.setTdlibParameters(
                apiHash: Secrets.apiHash,
                apiId: Secrets.apiId,
                applicationVersion: "Fignyagram \(version)",
                databaseDirectory: account.databaseDirectory,
                databaseEncryptionKey: nil,
                deviceModel: UIDevice.current.model,
                filesDirectory: account.filesDirectory,
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
        }
    }

    /// Runs a TDLib request, tracking the busy state and showing errors in the UI.
    func sendCallSignalingData(callId: Int, data: Data) {
        guard let client else {
            CallDiag.log("sendCallSignalingData: no client")
            return
        }
        Task {
            do {
                _ = try await client.sendCallSignalingData(callId: callId, data: data)
            } catch {
                CallDiag.log("sendCallSignalingData FAILED bytes=\(data.count) error=\(Self.describe(error))")
                self.errorMessage = Self.describe(error)
            }
        }
    }

    /// Read-only access to the underlying TDLib client for feature managers.
    var tdClient: TDLibClient? { client }

    private func perform(_ action: @escaping (TDLibClient) async throws -> Void) {
        guard let client else { return }
        isBusy = true
        errorMessage = nil
        // TDLibKit bridges some calls with unsafeForcedSync: running the action
        // on a detached executor keeps the main thread free even then.
        Task.detached(priority: .userInitiated) {
            do {
                try await action(client)
            } catch {
                let message = await MainActor.run(resultType: String.self) { Self.describe(error) }
                await MainActor.run { TelegramClient.shared.errorMessage = message }
            }
            await MainActor.run { TelegramClient.shared.isBusy = false }
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
        case "USERNAME_INVALID", "Username is invalid": return "Некорректное имя пользователя"
        case "Username not found", "USERNAME_NOT_FOUND": return "Пользователь с таким именем не найден"
        case "CHAT_TITLE_EMPTY", "Title can't be empty": return "Введите название"
        case "CHAT_TITLE_TOO_LONG", "Title is too long": return "Слишком длинное название (максимум 128 символов)"
        default: return message
        }
    }

    // MARK: - Updates

    private func handle(_ update: Update, clientId: Int32) {
        if case .updateAuthorizationState(let u) = update {
            DiagnosticsLog.log("authState \(u.authorizationState)")
        }
        if case .updateNewChat = update {
            DiagnosticsLog.log("updateNewChat")
        }
        guard clientId == client?.id else { return }

        switch update {
        case .updateAuthorizationState(let u):
            handleAuthState(u.authorizationState)

        case .updateNewChat(let u):
            store.enqueueChat(u.chat)
        case .updateChatTitle(let u):
            store.updateChat(u.chatId) { $0.title = u.title }
        case .updateChatPhoto(let u):
            store.updateChat(u.chatId) { $0.photo = u.photo }
        case .updateChatLastMessage(let u):
            store.enqueueChatUpdate(u.chatId, reorder: true) {
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
        case .updateChatNotificationSettings(let u):
            store.updateChat(u.chatId) { $0.notificationSettings = u.notificationSettings }
        case .updateChatBlockList(let u):
            store.updateChat(u.chatId) { $0.blockList = u.blockList }
            if let userId = store.chats[u.chatId]?.privateUserId {
                store.setUserBlocked(userId, isBlocked: u.blockList == .blockListMain)
            }
        case .updateScopeNotificationSettings(let u):
            AppNotifications.shared.update(scope: u.scope, settings: u.notificationSettings)
        case .updateChatAvailableReactions(let u):
            store.updateChat(u.chatId) { $0.availableReactions = u.availableReactions }
        case .updateChatAction(let u):
            if u.senderId != me.map({ .messageSenderUser(MessageSenderUser(userId: $0.id)) }) {
                store.setChatAction(chatId: u.chatId, sender: u.senderId, action: u.action)
            }

        case .updateNewMessage(let u):
            store.addMessage(u.message)
            ViewOnceStore.shared.preserveIfNeeded(u.message)
            AutomationEngine.shared.handle(u.message)
            AppNotifications.shared.notify(about: u.message, isChatOpen: u.message.chatId == openedChatId)
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
        case .updateGroupCall(let u):
            GroupCallManager.shared.handleGroupCallUpdate(u.groupCall)
        case .updateGroupCallParticipant(let u):
            GroupCallManager.shared.handleParticipant(u.participant)
        case .updateGroupCallParticipants(let u):
            GroupCallManager.shared.handleParticipantIds(u.participantUserIds.map { $0.rawValue })
        case .updateConnectionState(let u):
            CallDiag.log("connection=\(u.state)")
            if case .connectionStateConnecting = u.state {
                recentConnects.append(Foundation.Date())
                recentConnects = recentConnects.filter { Foundation.Date().timeIntervalSince($0) < 120 }
                CallDiag.log("reconnects in 120s=\(recentConnects.count) proxyEnabled=\(BuiltInProxyManager.shared.isEnabled)")
            }
            if case .connectionStateReady = u.state {
                // Account-wide recent contacts: throttled, capped imports.
                Task { await ContactsSync.shared.syncIfNeeded() }
            }
        case .updateNewCallSignalingData(let u):
            CallDiag.log("updateNewCallSignalingData callId=\(u.callId) bytes=\(u.data.count)")
            CallManager.shared.handleSignalingData(callId: u.callId, data: u.data)
        case .updateCall(let u):
            CallManager.shared.handle(update)
        case .updateDeleteMessages(let u):
            if u.isPermanent {
                let existing = (store.messages[u.chatId] ?? [])
                    .filter { u.messageIds.contains($0.id) }
                DeletedMessageStore.shared.archive(chatId: u.chatId, messages: existing)
                store.applyDeletedArchive(chatId: u.chatId)
                if !PrivacyPreferences.shared.keepDeletedMessages {
                    store.removeMessages(chatId: u.chatId, ids: u.messageIds)
                }
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
            needsTdlibParameters = true
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
            needsTdlibParameters = false
            onAuthorized()
        case .authorizationStateLoggingOut, .authorizationStateClosing:
            authStep = .loggingOut
        case .authorizationStateClosed:
            // Happens after logout: TDLib requires a brand new client instance.
            teardownSession()
            start()
        }
    }

    private func teardownSession() {
        parametersRetryTask?.cancel()
        parametersRetryTask = nil
        needsTdlibParameters = false
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
    }

    // MARK: - Accounts

    func switchAccount(to id: String) {
        guard id != AccountStore.shared.currentId else { return }
        let oldClient = client
        teardownSession()
        AccountStore.shared.switchTo(id: id)
        let target = AccountStore.shared.currentId
        if let oldClient {
            try? oldClient.close { [weak self] _ in
                Task { @MainActor in
                    guard self?.accountTargetIsCurrent(target) == true else { return }
                    self?.start()
                }
            }
        } else {
            start()
        }
    }

    func addAccount() {
        if !BuiltInProxyManager.shared.isEnabled {
            BuiltInProxyManager.shared.setEnabled(true)
        }
        let oldClient = client
        teardownSession()
        _ = AccountStore.shared.addAccount()
        let target = AccountStore.shared.currentId
        if let oldClient {
            try? oldClient.close { [weak self] _ in
                Task { @MainActor in
                    guard self?.accountTargetIsCurrent(target) == true else { return }
                    self?.start()
                }
            }
        } else {
            start()
        }
    }

    /// Cancels "Добавить аккаунт" and returns to the account that was active before.
    func cancelAddAccount() {
        guard let previous = AccountStore.shared.previousId,
              previous != AccountStore.shared.currentId else { return }
        let pendingId = AccountStore.shared.currentId
        let oldClient = client
        teardownSession()
        AccountStore.shared.remove(id: pendingId)
        AccountStore.shared.switchTo(id: previous)
        let target = AccountStore.shared.currentId
        if let oldClient {
            try? oldClient.close { [weak self] _ in
                Task { @MainActor in
                    guard self?.accountTargetIsCurrent(target) == true else { return }
                    self?.start()
                }
            }
        } else {
            start()
        }
    }

    /// Recreates the TDLib client for the current account. Used when an
    /// authorization request is stuck behind a dead proxy.
    func restartConnection() {
        let oldClient = client
        teardownSession()
        if let oldClient {
            try? oldClient.close { [weak self] _ in
                Task { @MainActor in self?.start() }
            }
        } else {
            start()
        }
    }

    private func accountTargetIsCurrent(_ target: String) -> Bool {
        AccountStore.shared.currentId == target
    }

    private func onAuthorized() {
        guard let client else { return }
        Task { await refreshInvisibleState() }
        AccountStore.shared.markAuthenticated(id: AccountStore.shared.currentId)
        Task {
            if let user = try? await client.getMe() {
                self.me = user
                self.store.setUser(user)
                let name = [user.firstName, user.lastName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !name.isEmpty {
                    AccountStore.shared.updateCurrentTitle(name)
                }
                AccountStore.shared.clearPrevious()
            }
        }
        loadMoreChats()
        loadBlockedUsers()
        Self.cleanOutgoingDirectory()

        // Local notifications for builds without an APNs server.
        AppNotifications.shared.requestAuthorization()
        Task { await AppNotifications.shared.refreshSettings(force: true) }

        Task {
            // Keeps the TDLib cache small: drops files unused for 3 days and caps the total at 300 MB.
            _ = try? await client.optimizeStorage(
                chatIds: [], chatLimit: 100, count: -1, excludeChatIds: [], fileTypes: [],
                immunityDelay: -1, returnDeletedFileStatistics: false, size: 300 * 1024 * 1024, ttl: 3 * 24 * 3600
            )
        }
    }

    /// Tells Telegram whether the app is in the foreground; TDLib keeps fewer connections when offline.
    @Published private(set) var isInvisible: Bool = UserDefaults.standard.bool(forKey: "invisibleModePersistent")

    func refreshInvisibleState() async {
        let remote = await isInvisibleMode()
        if UserDefaults.standard.bool(forKey: "invisibleModePersistent") {
            isInvisible = true
            if !remote { try? await setInvisibleMode(true) }
        } else {
            isInvisible = remote
        }
    }

    func setOnline(_ online: Bool) {
        guard let client, isAuthorized else { return }
        if online, isInvisible { return }
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

    // MARK: - Creating chats

    /// Creates a new channel or supergroup and returns its chat id.
    func createChannelOrGroup(title: String, description: String, isChannel: Bool) async throws -> Int64 {
        guard let client else { throw ChatCreationError.notReady }
        let chat = try await client.createNewSupergroupChat(
            description: description.isEmpty ? nil : String(description.prefix(255)),
            forImport: false,
            isChannel: isChannel,
            isForum: false,
            location: nil,
            messageAutoDeleteTime: 0,
            title: String(title.prefix(128))
        )
        store.addChat(chat)
        // New supergroups usually land in the main list on their own; this makes it immediate.
        try? await client.addChatToList(chatId: chat.id, chatList: .chatListMain)
        return chat.id
    }

    /// Resolves a public @username (or a t.me link) and opens the corresponding chat.
    func openChat(username raw: String) async throws -> Int64 {
        guard let client else { throw ChatCreationError.notReady }
        let username = Self.normalizedUsername(raw)
        guard !username.isEmpty else { throw ChatCreationError.emptyUsername }

        let chat = try await client.searchPublicChat(username: username)
        store.addChat(chat)
        try? await client.addChatToList(chatId: chat.id, chatList: .chatListMain)
        return chat.id
    }

    nonisolated private static func normalizedUsername(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "t.me/", options: .caseInsensitive) {
            name = String(name[range.upperBound...])
        }
        if name.hasPrefix("@") { name.removeFirst() }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// TDLib expects the database/files directories to exist and be writable.
    /// Creating them here also covers fresh account slots and protected-data timing.
    private static func prepareDirectories(for account: AccountSlot) -> String? {
        var isDirectory: ObjCBool = false
        let hadDatabase = FileManager.default.fileExists(
            atPath: account.databaseDirectory, isDirectory: &isDirectory
        ) && isDirectory.boolValue

        if let error = createDirectories(at: [account.databaseDirectory, account.filesDirectory]) {
            // Documents can be unavailable in rare sandbox/protection states.
            // Only fall back when there is no existing database to preserve.
            guard !hadDatabase else { return error }

            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FignyagramAccounts/", isDirectory: true)
                .appendingPathComponent(account.id, isDirectory: true)
            let database = support.appendingPathComponent("tdlib_db", isDirectory: true).path
            let files = support.appendingPathComponent("tdlib_files", isDirectory: true).path
            if let fallbackError = createDirectories(at: [database, files]) {
                return fallbackError
            }
            AccountStore.shared.relocate(id: account.id, databaseDirectory: database, filesDirectory: files)
        }
        return nil
    }

    private static func createDirectories(at paths: [String]) -> String? {
        let fileManager = FileManager.default
        for path in paths {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                try? fileManager.removeItem(atPath: path)
            }
            if !fileManager.fileExists(atPath: path) {
                do {
                    try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
                } catch {
                    return error.localizedDescription
                }
            }
            // Do not use NSFileProtectionComplete: TDLib must also work after reboot
            // before the first unlock (background/audio/notification cases).
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        }
        return nil
    }

    private func scheduleParametersRetry() {
        guard parametersRetryTask == nil else { return }
        parametersRetryTask = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.needsTdlibParameters, UIApplication.shared.isProtectedDataAvailable {
                    self.parametersRetryTask = nil
                    self.sendTdlibParameters()
                    return
                }
            }
            self?.parametersRetryTask = nil
        }
    }

    func retryTdlibParametersIfNeeded() {
        guard needsTdlibParameters, client != nil else { return }
        sendTdlibParameters()
    }

    // MARK: - Messages

    func openChat(_ chatId: Int64) {
        guard let client else { return }
        openedChatId = chatId
        ChatVisitHistory.shared.record(chatId: chatId)
        loadPinnedMessages(chatId: chatId)
        AppNotifications.shared.clearNotifications(chatId: chatId)
        Task { try? await client.openChat(chatId: chatId) }
        if store.isHistoryLoaded(chatId) {
            markAllAsRead(chatId: chatId)
        } else {
            loadHistory(chatId: chatId)
        }
    }

    func closeChat(_ chatId: Int64) {
        guard let client else { return }
        if openedChatId == chatId {
            openedChatId = nil
            // Updating the order while a NavigationLink is still on screen can pop it on iOS 15.
            store.setLastOpenedChat(chatId)
        }
        Task { try? await client.closeChat(chatId: chatId) }
    }

    /// Loads the newest messages of the chat.
    /// Marking stories as read is skipped entirely in ghost mode, so the author
    /// never sees the view. TDLib 1.8.68 in this build exposes no readStories
    /// binding yet, so the guard lives here for the upcoming stories UI.
    func readStoriesIfAllowed(_ markRead: () async -> Void) async {
        guard !PrivacyPreferences.shared.storyGhostMode else {
            CallDiag.log("story ghost mode: readStories skipped")
            return
        }
        await markRead()
    }

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
                // Preparation stays off the main thread: only the ready array is
                // handed back for a single @Published assignment.
                let raw = collected
                let prepared = await Task.detached(priority: .userInitiated) {
                    raw.sorted { $0.id < $1.id }
                }.value
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.store.setHistory(chatId: chatId, messages: prepared)
                }
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
            // TDLib may still return the previous revision right after an edit,
            // so retry a few times and stop once editDate changes.
            let previousEditDate = store.message(chatId: chatId, id: messageId)?.editDate ?? 0
            for attempt in 0..<6 {
                if let message = try? await client.getMessage(chatId: chatId, messageId: messageId) {
                    self.store.replaceMessage(chatId: chatId, oldId: messageId, with: message)
                    if message.editDate > previousEditDate || attempt >= 2 { break }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
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

    // MARK: - Search

    /// Finds messages in one chat (when `chatId` is set) or across all main chats and channels.
    func searchMessages(_ query: String, chatId: Int64? = nil, limit: Int = 40) async throws -> [TDLibKit.Message] {
        guard let client else { throw ChatCreationError.notReady }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        if let chatId {
            let found = try await client.searchChatMessages(
                chatId: chatId, filter: nil, fromMessageId: 0, limit: limit, offset: 0,
                query: text, senderId: nil, topicId: nil
            )
            return found.messages
        } else {
            let found = try await client.searchMessages(
                chatList: .chatListMain, chatTypeFilter: nil, filter: nil, limit: limit,
                maxDate: 0, minDate: 0, offset: "", query: text
            )
            return found.messages
        }
    }

    /// Loads a page of history around a message, so a search result can be revealed and scrolled to.
    func loadContext(chatId: Int64, messageId: Int64) async {
        guard let client else { return }
        do {
            var context = try await client.getChatHistory(
                chatId: chatId, fromMessageId: messageId, limit: 50, offset: 0, onlyLocal: false
            ).messages ?? []
            if let target = try? await client.getMessage(chatId: chatId, messageId: messageId) {
                context.append(target)
            }
            store.setHistory(chatId: chatId, messages: context)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// Searches Telegram contacts by name or @username.
    func searchContacts(_ query: String, limit: Int = 20) async throws -> [TDLibKit.User] {
        guard let client else { throw ChatCreationError.notReady }
        let text = Self.searchTerm(query)
        guard !text.isEmpty else { return [] }

        let ids = try await client.searchContacts(limit: limit, query: text).userIds
        var users: [TDLibKit.User] = []
        var seen = Set<Int64>()
        for id in ids {
            if let user = try? await client.getUser(userId: id) {
                store.setUser(user)
                if seen.insert(user.id).inserted {
                    users.append(user)
                }
            }
        }

        // TDLib's contact search can require a full name; add fuzzy local matches.
        for user in store.users.values where user.isContact && !seen.contains(user.id) {
            let username = user.usernames?.activeUsernames.first ?? ""
            let name = [user.firstName, user.lastName, username]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if SearchMatcher.matches(name, query: text) {
                users.append(user)
                seen.insert(user.id)
                if users.count >= limit { break }
            }
        }
        return Array(users.prefix(limit))
    }

    /// Searches channels by title or @username. Runs the full query and its words
    /// separately, because TDLib's server search often needs a complete title/tag.
    func searchChannels(_ query: String, limit: Int = 20) async throws -> [Int64] {
        guard let client else { throw ChatCreationError.notReady }
        let text = Self.searchTerm(query)
        guard !text.isEmpty else { return [] }

        var variants = [text]
        let tokens = text.split(separator: " ").map(String.init)
        if tokens.count > 1 {
            variants += tokens.prefix(2)
        }

        var ids: [Int64] = []
        var seen = Set<Int64>()

        for variant in variants {
            if let known = try? await client.searchChats(
                limit: limit, query: variant, typeFilter: .searchChatTypeFilterChannel
            ) {
                for id in known.chatIds where seen.insert(id).inserted {
                    ids.append(id)
                }
            }
            if let server = try? await client.searchChatsOnServer(
                limit: limit, query: variant, typeFilter: .searchChatTypeFilterChannel
            ) {
                for id in server.chatIds where seen.insert(id).inserted {
                    if store.chats[id] == nil, let chat = try? await client.getChat(chatId: id) {
                        store.addChat(chat)
                    }
                    ids.append(id)
                }
            }
            if let publicChats = try? await client.searchPublicChats(
                query: variant, typeFilter: .searchChatTypeFilterChannel
            ) {
                for id in publicChats.chatIds.prefix(limit) where seen.insert(id).inserted {
                    if store.chats[id] == nil {
                        guard let chat = try? await client.getChat(chatId: id) else { continue }
                        store.addChat(chat)
                    }
                    ids.append(id)
                }
            }
            if ids.count >= limit { break }
        }

        return Array(ids.prefix(limit))
    }

    /// Opens (or creates) the private chat with a user, e.g. a contact from search.
    func openChat(userId: Int64) async throws -> Int64 {
        guard let client else { throw ChatCreationError.notReady }
        let chat = try await client.createPrivateChat(force: false, userId: userId)
        store.addChat(chat)
        try? await client.addChatToList(chatId: chat.id, chatList: .chatListMain)
        return chat.id
    }

    /// Strips a leading "@" so a tag can be passed to TDLib search methods.
    nonisolated private static func searchTerm(_ raw: String) -> String {
        var term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.hasPrefix("@") { term.removeFirst() }
        return term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Notifications

    func notificationSettings(scope: NotificationSettingsScope) async throws -> ScopeNotificationSettings {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.getScopeNotificationSettings(scope: scope)
    }

    func setNotificationSettings(scope: NotificationSettingsScope, settings: ScopeNotificationSettings) async throws {
        guard let client else { throw ChatCreationError.notReady }
        _ = try await client.setScopeNotificationSettings(notificationSettings: settings, scope: scope)
    }

    func setChatNotificationSettings(chatId: Int64, settings: ChatNotificationSettings) async throws {
        guard let client else { throw ChatCreationError.notReady }
        store.updateChat(chatId) { $0.notificationSettings = settings }
        _ = try await client.setChatNotificationSettings(chatId: chatId, notificationSettings: settings)
    }

    func resetAllNotificationSettings() {
        perform { _ = try await $0.resetAllNotificationSettings() }
    }

    // MARK: - Profile

    func isInvisibleMode() async -> Bool {
        guard let client,
              let rules = try? await client.getUserPrivacySettingRules(setting: .userPrivacySettingShowStatus) else {
            return false
        }
        return rules.rules.contains { rule in
            if case .userPrivacySettingRuleRestrictAll = rule { return true }
            return false
        }
    }

    /// Re-applies the invisible privacy rules after actions that can reset the
    /// status (sending messages, reconnects, foreground transitions).
    func enforceInvisibleIfNeeded() async {
        guard isInvisible, let client else { return }
        let rules = UserPrivacySettingRules(rules: [.userPrivacySettingRuleRestrictAll])
        _ = try? await client.setUserPrivacySettingRules(
            rules: rules, setting: .userPrivacySettingShowStatus
        )
        _ = try? await client.setOption(
            name: "online",
            value: .optionValueBoolean(OptionValueBoolean(value: false))
        )
    }

    func setInvisibleMode(_ enabled: Bool) async throws {
        guard let client else { throw ChatCreationError.notReady }
        isInvisible = enabled
        UserDefaults.standard.set(enabled, forKey: "invisibleModePersistent")
        _ = try? await client.setOption(
            name: "online",
            value: .optionValueBoolean(OptionValueBoolean(value: enabled ? false : true))
        )
        let rules = UserPrivacySettingRules(rules: [
            enabled ? .userPrivacySettingRuleRestrictAll : .userPrivacySettingRuleAllowAll
        ])
        _ = try await client.setUserPrivacySettingRules(
            rules: rules,
            setting: .userPrivacySettingShowStatus
        )
    }

    @discardableResult
    func refreshMe() async -> TDLibKit.User? {
        guard let client else { return nil }
        guard let user = try? await client.getMe() else { return nil }
        me = user
        store.setUser(user)
        return user
    }

    func updateProfile(firstName: String, lastName: String, bio: String, username: String) async throws {
        guard let client else { throw ChatCreationError.notReady }
        try await client.setName(firstName: firstName, lastName: lastName)
        try await client.setBio(bio: bio.isEmpty ? nil : bio)
        try await client.setUsername(username: username.isEmpty ? nil : username)
        if let user = try? await client.getMe() {
            me = user
            store.setUser(user)
        }
    }

    func updateProfilePhoto(_ url: URL) async throws {
        guard let client else { throw ChatCreationError.notReady }
        let input = InputChatPhoto.inputChatPhotoStatic(InputChatPhotoStatic(photo: Self.local(url)))
        try await client.setProfilePhoto(isPublic: true, photo: input)
        if let user = try? await client.getMe() {
            me = user
            store.setUser(user)
        }
    }

    func removeProfilePhoto() async throws {
        guard let client else { throw ChatCreationError.notReady }
        try await client.setProfilePhoto(isPublic: true, photo: nil)
        if let user = try? await client.getMe() {
            me = user
            store.setUser(user)
        }
    }

    func currentBio() async -> String {
        guard let client, let me else { return "" }
        guard let info = try? await client.getUserFullInfo(userId: me.id) else { return "" }
        return info.bio?.text ?? ""
    }

    func confirmQrLogin(_ link: String) {
        guard let client else { return }
        Task {
            do {
                _ = try await client.confirmQrCodeAuthentication(link: link)
            } catch {
                errorMessage = Self.describe(error)
            }
        }
    }

    /// Confirms a QR login on another device using the currently selected account.
    func confirmOtherDeviceLogin(_ link: String) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.confirmQrCodeAuthentication(link: link)
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    // MARK: - Username suggestions

    struct UsernameSuggestion: Identifiable {
        let username: String
        let title: String
        let isBot: Bool
        var id: String { username }
    }

    func usernameSuggestions(_ rawQuery: String) async -> [UsernameSuggestion] {
        guard let client else { return [] }
        let query = rawQuery
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        var chatIds: [Int64] = []
        var seenChats = Set<Int64>()
        if let known = try? await client.searchChatsOnServer(
            limit: 20, query: query, typeFilter: nil
        ) {
            for id in known.chatIds where seenChats.insert(id).inserted {
                chatIds.append(id)
            }
        }
        if let publicChats = try? await client.searchPublicChats(
            query: query, typeFilter: nil
        ) {
            for id in publicChats.chatIds.prefix(20) where seenChats.insert(id).inserted {
                chatIds.append(id)
            }
        }

        var result: [UsernameSuggestion] = []
        var seenUsernames = Set<String>()

        func append(username: String, title: String, isBot: Bool) {
            let name = username.lowercased()
            guard !seenUsernames.contains(name) else { return }
            guard name.contains(query.lowercased()) else { return }
            seenUsernames.insert(name)
            result.append(UsernameSuggestion(username: username, title: title, isBot: isBot))
        }

        for chatId in chatIds {
            guard result.count < 12 else { break }
            if store.chats[chatId] == nil,
               let fetched = try? await client.getChat(chatId: chatId) {
                store.addChat(fetched)
            }
            guard let chat = store.chats[chatId] else { continue }

            if let userId = chat.privateUserId {
                var user = store.users[userId]
                if user == nil {
                    user = try? await client.getUser(userId: userId)
                }
                guard let user else { continue }
                store.setUser(user)
                let name = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
                var isBot = false
                if case .userTypeBot = user.type { isBot = true }
                if let username = user.usernames?.activeUsernames.first {
                    append(username: username, title: name, isBot: isBot)
                }
            } else if case .chatTypeSupergroup(let supergroup) = chat.type {
                if let info = try? await client.getSupergroup(supergroupId: supergroup.supergroupId),
                   let username = info.usernames?.activeUsernames.first {
                    append(username: username, title: chat.title, isBot: false)
                }
            }
        }

        // Contacts and already-known users are useful even before a server response.
        for user in store.users.values {
            guard result.count < 12 else { break }
            guard let username = user.usernames?.activeUsernames.first else { continue }
            var isBot = false
            if case .userTypeBot = user.type { isBot = true }
            let name = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            append(username: username, title: name, isBot: isBot)
        }

        return result.sorted {
            let lhsStarts = $0.username.lowercased().hasPrefix(query.lowercased())
            let rhsStarts = $1.username.lowercased().hasPrefix(query.lowercased())
            if lhsStarts != rhsStarts { return lhsStarts }
            return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }
    }

    // MARK: - Message replies

    func messageThread(chatId: Int64, messageId: Int64) async -> [TDLibKit.Message] {
        guard let client else { return [] }
        guard let result = try? await client.getMessageThreadHistory(
            chatId: chatId,
            fromMessageId: 0,
            limit: 100,
            messageId: messageId,
            offset: 0
        ) else { return [] }
        return (result.messages ?? []).sorted { $0.id < $1.id }
    }

    // MARK: - Peer information

    struct PeerInfo {
        let title: String
        let typeText: String
        let description: String
        let username: String?
        let phone: String?
        let memberCount: Int?
        let photo: ChatPhotoInfo?
        var userId: Int64? = nil
        var linkedChatId: Int64? = nil
        var directMessagesChatId: Int64? = nil
    }

    func avatarPhotos(chatId: Int64) async -> [AvatarPhoto] {
        guard let client, let chat = store.chats[chatId] else { return [] }
        var photos: [AvatarPhoto] = []
        if let userId = chat.privateUserId {
            if let result = try? await client.getUserProfilePhotos(limit: 100, offset: 0, userId: userId) {
                photos = result.photos.compactMap { photo in
                    guard let size = photo.sizes
                        .filter({ $0.photo.size > 0 || !$0.photo.remote.id.isEmpty })
                        .max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
                    return AvatarPhoto(id: Int(photo.id.rawValue), file: size.photo)
                }
            }
        }
        if let big = chat.photo?.big, !photos.contains(where: { $0.file.id == big.id }) {
            photos.insert(AvatarPhoto(id: Int(big.id), file: big), at: 0)
        }
        return photos
    }

    func peerInfo(chatId: Int64) async -> PeerInfo? {
        guard let client, let chat = store.chats[chatId] else { return nil }

        if let userId = chat.privateUserId {
            var user = store.users[userId]
            if user == nil {
                user = try? await client.getUser(userId: userId)
            }
            guard let user else { return nil }
            store.setUser(user)
            let full = try? await client.getUserFullInfo(userId: userId)
            var photo: ChatPhotoInfo?
            if let p = user.profilePhoto {
                photo = ChatPhotoInfo(
                    big: p.big,
                    hasAnimation: p.hasAnimation,
                    isPersonal: p.isPersonal,
                    minithumbnail: p.minithumbnail,
                    small: p.small
                )
            }
            return PeerInfo(
                title: [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "),
                typeText: {
                    if case .userTypeBot = user.type { return "бот" }
                    return "пользователь"
                }(),
                description: full?.bio?.text ?? "",
                username: user.usernames?.activeUsernames.first,
                phone: user.phoneNumber.isEmpty ? nil : "+\(user.phoneNumber)",
                memberCount: nil,
                photo: photo,
                userId: user.id
            )
        }

        if case .chatTypeSupergroup(let supergroup) = chat.type {
            let full = try? await client.getSupergroupFullInfo(supergroupId: supergroup.supergroupId)
            let info = try? await client.getSupergroup(supergroupId: supergroup.supergroupId)
            return PeerInfo(
                title: chat.title,
                typeText: supergroup.isChannel ? "канал" : "группа",
                description: full?.description ?? "",
                username: info?.usernames?.activeUsernames.first,
                phone: nil,
                memberCount: full?.memberCount,
                photo: chat.photo,
                linkedChatId: (full?.linkedChatId ?? 0) != 0 ? full?.linkedChatId : nil,
                directMessagesChatId: (full?.directMessagesChatId ?? 0) != 0 ? full?.directMessagesChatId : nil
            )
        }

        if case .chatTypeBasicGroup(let basic) = chat.type {
            let full = try? await client.getBasicGroupFullInfo(basicGroupId: basic.basicGroupId)
            return PeerInfo(
                title: chat.title,
                typeText: "группа",
                description: full?.description ?? "",
                username: nil,
                phone: nil,
                memberCount: full?.members.count,
                photo: chat.photo
            )
        }

        return PeerInfo(
            title: chat.title,
            typeText: "чат",
            description: "",
            username: nil,
            phone: nil,
            memberCount: nil,
            photo: chat.photo
        )
    }

    // MARK: - Member tags

    struct MemberTagInfo: Equatable {
        let text: String
        let isAdmin: Bool
    }

    private var memberTags: [String: MemberTagInfo] = [:]

    func memberTagInfo(chatId: Int64, userId: Int64) async -> MemberTagInfo? {
        let key = "\(chatId):\(userId)"
        if let cached = memberTags[key] { return cached.text.isEmpty ? nil : cached }
        guard let client else { return nil }
        guard let member = try? await client.getChatMember(
            chatId: chatId,
            memberId: .messageSenderUser(MessageSenderUser(userId: userId))
        ) else { return nil }
        let tag = member.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAdmin: Bool
        switch member.status {
        case .chatMemberStatusAdministrator, .chatMemberStatusCreator:
            isAdmin = true
        default:
            isAdmin = false
        }
        if memberTags.count > 2000 { memberTags.removeAll(keepingCapacity: true) }
        let info = MemberTagInfo(text: tag, isAdmin: isAdmin)
        memberTags[key] = info
        return tag.isEmpty ? nil : info
    }

    func prefetchMemberTags(chatId: Int64) async {
        guard let chat = store.chats[chatId], chat.isGroup else { return }
        let members = await chatMembers(chatId: chatId)
        for member in members {
            memberTags["\(chatId):\(member.id)"] = MemberTagInfo(
                text: member.tag,
                isAdmin: member.isAdmin
            )
        }
    }

    func memberTag(chatId: Int64, userId: Int64) async -> String? {
        await memberTagInfo(chatId: chatId, userId: userId)?.text
    }

    struct ChatMemberItem: Identifiable {
        let id: Int64
        let name: String
        let tag: String
        let isAdmin: Bool
        let isCreator: Bool
        let isBanned: Bool
        let username: String?
    }

    func chatMembers(chatId: Int64, adminsOnly: Bool = false, query: String = "") async -> [ChatMemberItem] {
        guard let client, let chat = store.chats[chatId] else { return [] }
        var raw: [ChatMember] = []

        if case .chatTypeSupergroup(let supergroup) = chat.type {
            let filter: SupergroupMembersFilter
            if !query.isEmpty {
                filter = .supergroupMembersFilterSearch(SupergroupMembersFilterSearch(query: query))
            } else if adminsOnly {
                filter = .supergroupMembersFilterAdministrators
            } else {
                filter = .supergroupMembersFilterRecent
            }
            if let result = try? await client.getSupergroupMembers(
                filter: filter, limit: 200, offset: 0,
                supergroupId: supergroup.supergroupId
            ) {
                raw = result.members
            }
        } else if case .chatTypeBasicGroup(let basic) = chat.type {
            if let full = try? await client.getBasicGroupFullInfo(basicGroupId: basic.basicGroupId) {
                raw = full.members
            }
        }

        let filtered = raw.filter { member in
            guard case .messageSenderUser(let sender) = member.memberId else { return false }
            let user = store.users[sender.userId]
            let name = store.senderName(member.memberId)
            if !query.isEmpty, !SearchMatcher.matches(name, query: query) { return false }
            let isAdmin: Bool
            switch member.status {
            case .chatMemberStatusAdministrator, .chatMemberStatusCreator: isAdmin = true
            default: isAdmin = false
            }
            return !adminsOnly || isAdmin
        }

        return filtered.compactMap { member in
            guard case .messageSenderUser(let sender) = member.memberId else { return nil }
            let isCreator: Bool
            if case .chatMemberStatusCreator = member.status { isCreator = true } else { isCreator = false }
            let isBanned: Bool
            if case .chatMemberStatusBanned = member.status { isBanned = true } else { isBanned = false }
            let isAdmin: Bool
            switch member.status {
            case .chatMemberStatusAdministrator, .chatMemberStatusCreator: isAdmin = true
            default: isAdmin = false
            }
            let user = store.users[sender.userId]
            return ChatMemberItem(
                id: sender.userId,
                name: store.senderName(member.memberId),
                tag: member.tag,
                isAdmin: isAdmin,
                isCreator: isCreator,
                isBanned: isBanned,
                username: user?.usernames?.activeUsernames.first
            )
        }
    }

    func addChatMember(chatId: Int64, userId: Int64) async throws {
        guard let client else { throw ChatCreationError.notReady }
        let result = try await client.addChatMember(chatId: chatId, forwardLimit: 50, userId: userId)
        if let failed = result.failedToAddMembers.first {
            throw ChatCreationError.notReady
        }
    }

    func banChatMember(chatId: Int64, userId: Int64, banned: Bool) async throws {
        guard let client else { throw ChatCreationError.notReady }
        let status: ChatMemberStatus = banned
            ? .chatMemberStatusBanned(ChatMemberStatusBanned(bannedUntilDate: 0))
            : .chatMemberStatusMember(ChatMemberStatusMember(memberUntilDate: 0))
        try await client.setChatMemberStatus(
            chatId: chatId,
            memberId: .messageSenderUser(MessageSenderUser(userId: userId)),
            status: status
        )
    }

    func promoteChatMember(
        chatId: Int64, userId: Int64,
        rights: ChatAdministratorRights
    ) async throws {
        guard let client else { throw ChatCreationError.notReady }
        try await client.setChatMemberStatus(
            chatId: chatId,
            memberId: .messageSenderUser(MessageSenderUser(userId: userId)),
            status: .chatMemberStatusAdministrator(
                ChatMemberStatusAdministrator(canBeEdited: true, rights: rights)
            )
        )
    }

    func demoteChatMember(chatId: Int64, userId: Int64) async throws {
        guard let client else { throw ChatCreationError.notReady }
        try await client.setChatMemberStatus(
            chatId: chatId,
            memberId: .messageSenderUser(MessageSenderUser(userId: userId)),
            status: .chatMemberStatusMember(ChatMemberStatusMember(memberUntilDate: 0))
        )
    }

    func setMemberTag(chatId: Int64, userId: Int64, tag: String) async throws {
        guard let client else { throw ChatCreationError.notReady }
        let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.setChatMemberTag(chatId: chatId, tag: value.isEmpty ? nil : value, userId: userId)
        let old = memberTags["\(chatId):\(userId)"]
        memberTags["\(chatId):\(userId)"] = MemberTagInfo(text: value, isAdmin: old?.isAdmin ?? false)
        Foundation.NotificationCenter.default.post(
            name: Foundation.Notification.Name("fignyagramMemberTagChanged"),
            object: nil,
            userInfo: ["chatId": chatId, "userId": userId]
        )
    }

    // MARK: - Cloud password

    func passwordState() async throws -> PasswordState {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.getPasswordState()
    }

    func updateCloudPassword(
        oldPassword: String,
        newPassword: String,
        hint: String,
        recoveryEmail: String,
        setRecoveryEmail: Bool
    ) async throws -> PasswordState {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.setPassword(
            newHint: hint,
            newPassword: newPassword,
            newRecoveryEmailAddress: recoveryEmail,
            oldPassword: oldPassword,
            setRecoveryEmailAddress: setRecoveryEmail
        )
    }

    func requestPasswordRecovery() async throws -> EmailAddressAuthenticationCodeInfo {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.requestPasswordRecovery()
    }

    func recoverCloudPassword(
        code: String,
        newPassword: String,
        hint: String
    ) async throws -> PasswordState {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.recoverPassword(
            newHint: hint,
            newPassword: newPassword,
            recoveryCode: code
        )
    }

    func changeRecoveryEmail(password: String, email: String) async throws -> PasswordState {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.setRecoveryEmailAddress(
            newRecoveryEmailAddress: email,
            password: password
        )
    }

    // MARK: - Chat editing

    /// Leaves a group/channel (or deletes a basic-group chat where TDLib
    /// requires it). Returns normally if already not a member.
    func leaveChat(_ chatId: Int64) async throws {
        guard let client else { throw ChatCreationError.notReady }
        try await client.leaveChat(chatId: chatId)
        store.removeChat(chatId)
    }

    func updateChatProfile(
        chatId: Int64,
        title: String,
        description: String,
        username: String?,
        photo: UIImage?
    ) async throws {
        guard let client else { throw ChatCreationError.notReady }
        try await client.setChatTitle(chatId: chatId, title: title)
        try await client.setChatDescription(chatId: chatId, description: description)

        if let username,
           case .chatTypeSupergroup(let supergroup) = store.chats[chatId]?.type {
            _ = try? await client.setSupergroupUsername(
                supergroupId: supergroup.supergroupId,
                username: username.isEmpty ? nil : username
            )
        }

        if let photo, let prepared = MediaPreparer.photo(photo) {
            let input = InputChatPhoto.inputChatPhotoStatic(
                InputChatPhotoStatic(photo: Self.local(prepared.url))
            )
            try await client.setChatPhoto(chatId: chatId, photo: input)
        }

        if let chat = try? await client.getChat(chatId: chatId) {
            store.addChat(chat)
        }
    }

    func resendMessage(chatId: Int64, messageId: Int64) {
        guard let client else { return }
        Task {
            do {
                _ = try await client.resendMessages(
                    chatId: chatId,
                    messageIds: [messageId],
                    paidMessageStarCount: 0,
                    quote: nil
                )
            } catch {
                self.errorMessage = Self.describe(error)
            }
        }
    }

    // MARK: - Downloads and cache

    func cancelDownload(_ file: TDLibKit.File) {
        guard let client else { return }
        // Allow the user to tap download again immediately after cancelling.
        requestedDownloads.remove(file.id)
        Task {
            _ = try? await client.cancelDownloadFile(fileId: file.id, onlyIfPending: false)
        }
    }

    func deleteDownloadedFile(_ file: TDLibKit.File) {
        guard let client else { return }
        Task {
            _ = try? await client.deleteFile(fileId: file.id)
            FileStore.shared.remove(fileId: file.id)
        }
    }

    func clearFileCache() {
        guard let client else { return }
        let files = FileStore.shared.downloadedFiles
        Task {
            for file in files {
                _ = try? await client.deleteFile(fileId: file.id)
            }
            FileStore.shared.reset()
            ImageCache.clear()
        }
    }

    // MARK: - Profile music

    func profileAudios(userId: Int64? = nil) async -> [TDLibKit.Audio] {
        guard let client else { return [] }
        guard let target = userId ?? me?.id else { return [] }
        guard let result = try? await client.getUserProfileAudios(
            limit: 100, offset: 0, userId: target
        ) else { return [] }
        return result.audios
    }

    func addToProfileAudio(_ track: MusicTrack) async {
        guard let client else { return }
        let audio = InputAudio(
            albumCoverThumbnail: nil,
            audio: Self.local(MusicLibrary.shared.url(for: track)),
            duration: track.duration ?? 0,
            performer: track.artist,
            title: track.title
        )
        do {
            _ = try await client.addProfileAudio(audio: audio)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func removeFromProfileAudio(_ audio: TDLibKit.Audio) async {
        guard let client else { return }
        do {
            _ = try await client.removeProfileAudio(fileId: audio.audio.id)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func moveProfileAudioToTop(_ audio: TDLibKit.Audio) async {
        guard let client else { return }
        do {
            _ = try await client.setProfileAudioPosition(afterFileId: 0, fileId: audio.audio.id)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Linked chat

    /// Discussion group for a channel, or the channel linked to a discussion group.
    func linkedChatId(for chatId: Int64) async -> Int64? {
        guard let client,
              case .chatTypeSupergroup(let supergroup) = store.chats[chatId]?.type else { return nil }
        guard let info = try? await client.getSupergroupFullInfo(supergroupId: supergroup.supergroupId),
              info.linkedChatId != 0 else { return nil }
        return info.linkedChatId
    }

    // MARK: - Username links

    func resolveUsername(_ username: String) async -> Int64? {
        guard let client else { return nil }
        let name = username.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        guard !name.isEmpty else { return nil }
        guard let chat = try? await client.searchPublicChat(username: name) else { return nil }
        store.addChat(chat)
        return chat.id
    }

    // MARK: - Audio in chats

    /// All audio-file messages in a chat/channel, newest first.
    func callProtocol() -> CallProtocol {
        // Only 13.0.0 maps to a fully implemented engine path in this build
        // (InstanceV2Impl). 14.0.0 selects InstanceV2CompatImpl, whose
        // SignalingTranslator object is missing from the prebuilt archive, and
        // 10-12 use the legacy signaling API that is stubbed out.
        // Only versions implemented by InstanceV2Impl are advertised: 14.0.0
        // would select the compat implementation whose SignalingTranslator is
        // missing from the prebuilt engine archive, and 10/11 have no engine
        // implementation at all. Older versions let third-party clients that
        // don't know 13.0.0 negotiate a working protocol.
        CallProtocol(libraryVersions: ["13.0.0", "12.0.0"],
                     maxLayer: 92, minLayer: 65, udpP2p: true, udpReflector: true)
    }

    /// Starts an in-app call through TDLib (signaling goes through the proxy).
    func startCall(userId: Int64, isVideo: Bool = false) async {
        guard VoIPBridge.engineAvailable() else {
            // Without a working media engine TDLib would create a call whose
            // DH handshake cannot complete, so the user would get a hung call.
            errorMessage = "Встроенный VoIP-движок отключён в этой сборке"
            return
        }
        guard let client else { return }
        do {
            let result = try await client.createCall(isVideo: isVideo, protocol: callProtocol(), userId: userId)
            CallDiag.log("createCall ok video=\(isVideo) callId=\(result.id) versions=\(callProtocol().libraryVersions.joined(separator: ","))")
            CallManager.shared.setStatus("Набор номера…")
        } catch {
            CallDiag.log("createCall FAILED video=\(isVideo) error=\(Self.describe(error))")
            errorMessage = Self.describe(error)
        }
    }

    func acceptCall() async {
        guard let client, let call = CallManager.shared.currentCall else {
            CallDiag.log("acceptCall: no current call")
            return
        }
        do {
            _ = try await client.acceptCall(callId: call.id, protocol: callProtocol())
            CallManager.shared.markAccepted()
            CallDiag.log("acceptCall ok callId=\(call.id)")
        } catch {
            CallDiag.log("acceptCall FAILED callId=\(call.id) error=\(Self.describe(error))")
            errorMessage = Self.describe(error)
        }
    }

    /// Ends a specific call without consulting CallManager (used by the
    /// detached teardown path).
    func discardCall(callId: Int) async {
        guard let client else { return }
        _ = try? await client.discardCall(callId: callId, connectionId: 0, duration: 0,
                                          inviteLink: nil, isDisconnected: false, isVideo: false)
    }

    func discardCall() async {
        guard let client, let call = CallManager.shared.currentCall else { return }
        do {
            _ = try await client.discardCall(
                callId: call.id, connectionId: 0, duration: 0,
                inviteLink: nil, isDisconnected: false, isVideo: call.isVideo
            )
            CallDiag.log("discardCall ok callId=\(call.id)")
        } catch {
            CallDiag.log("discardCall FAILED callId=\(call.id) error=\(Self.describe(error))")
            errorMessage = Self.describe(error)
        }
    }

    func activeSessions() async -> [Session] {
        guard let client, let result = try? await client.getActiveSessions() else { return [] }
        return result.sessions
    }

    func terminateSession(_ id: TdInt64) async throws {
        guard let client else { throw ChatCreationError.notReady }
        _ = try await client.terminateSession(sessionId: id)
    }

    func terminateOtherSessions() async throws {
        guard let client else { throw ChatCreationError.notReady }
        _ = try await client.terminateAllOtherSessions()
    }

    func availableGifts() async -> [AvailableGift] {
        guard let client, let result = try? await client.getAvailableGifts() else { return [] }
        return result.gifts
    }

    func sendGift(_ gift: Gift, to sender: MessageSender) async throws {
        guard let client else { throw ChatCreationError.notReady }
        _ = try await client.sendGift(
            giftId: gift.id, isPrivate: false, ownerId: sender,
            payForUpgrade: false, text: nil
        )
    }

    func chatMediaMessages(chatId: Int64, filter: SearchMessagesFilter, limit: Int = 200) async -> [TDLibKit.Message] {
        guard let client else { return [] }
        var result: [TDLibKit.Message] = []
        var fromMessageId: Int64 = 0
        while result.count < limit {
            guard let found = try? await client.searchChatMessages(
                chatId: chatId,
                filter: filter,
                fromMessageId: fromMessageId,
                limit: min(100, limit - result.count),
                offset: 0,
                query: "",
                senderId: nil,
                topicId: nil
            ), !found.messages.isEmpty else { break }
            result.append(contentsOf: found.messages)
            guard found.nextFromMessageId != 0, found.nextFromMessageId != fromMessageId else { break }
            fromMessageId = found.nextFromMessageId
        }
        return result
    }

    func audioMessages(chatId: Int64, limit: Int = 500) async -> [TDLibKit.Message] {
        guard let client else { return [] }
        var result: [TDLibKit.Message] = []
        var seen = Set<Int64>()
        var fromMessageId: Int64 = 0

        while result.count < limit {
            guard let found = try? await client.searchChatMessages(
                chatId: chatId,
                filter: .searchMessagesFilterAudio,
                fromMessageId: fromMessageId,
                limit: min(100, limit - result.count),
                offset: 0,
                query: "",
                senderId: nil,
                topicId: nil
            ), !found.messages.isEmpty else { break }

            for message in found.messages where seen.insert(message.id).inserted {
                result.append(message)
            }
            guard found.nextFromMessageId != 0, found.nextFromMessageId != fromMessageId else { break }
            fromMessageId = found.nextFromMessageId
        }

        // Documents with audio extensions (wav, ogg, opus, flac, …) are music too.
        let audioExts: Set<String> = ["mp3","m4a","aac","wav","aiff","aif","flac","ogg","opus","wma","caf"]
        var docFrom: Int64 = 0
        while result.count < limit {
            guard let found = try? await client.searchChatMessages(
                chatId: chatId,
                filter: .searchMessagesFilterDocument,
                fromMessageId: docFrom,
                limit: min(100, limit - result.count),
                offset: 0,
                query: "",
                senderId: nil,
                topicId: nil
            ), !found.messages.isEmpty else { break }
            for message in found.messages where seen.insert(message.id).inserted {
                if case .messageDocument(let doc) = message.content,
                   audioExts.contains((doc.document.fileName as NSString).pathExtension.lowercased()) {
                    result.append(message)
                }
            }
            guard found.nextFromMessageId != 0, found.nextFromMessageId != docFrom else { break }
            docFrom = found.nextFromMessageId
        }
        return result
    }

    // MARK: - Pinned messages

    /// Pinned messages can be delivered without their content (only the id is
    /// valid). Fetch the full message so the banner shows a preview.
    func refreshPinnedMessage(chatId: Int64, messageId: Int64) {
        Task {
            guard let client, let message = try? await client.getMessage(chatId: chatId, messageId: messageId) else { return }
            store.replacePinnedMessage(message, chatId: chatId)
        }
    }

    func loadPinnedMessages(chatId: Int64) {
        guard let client else { return }
        Task {
            if let found = try? await client.searchChatMessages(
                chatId: chatId,
                filter: .searchMessagesFilterPinned,
                fromMessageId: 0,
                limit: 50,
                offset: 0,
                query: "",
                senderId: nil,
                topicId: nil
            ) {
                store.setPinnedMessages(found.messages, chatId: chatId)
            } else if let newest = try? await client.getChatPinnedMessage(chatId: chatId) {
                store.setPinnedMessages([newest], chatId: chatId)
            } else {
                store.setPinnedMessages([], chatId: chatId)
            }
        }
    }

    func pinMessage(_ message: TDLibKit.Message) {
        guard let client else { return }
        Task {
            do {
                try await client.pinChatMessage(
                    chatId: message.chatId,
                    disableNotification: true,
                    messageId: message.id,
                    onlyForSelf: false
                )
                store.addPinnedMessage(message)
                loadPinnedMessages(chatId: message.chatId)
            } catch {
                errorMessage = Self.describe(error)
            }
        }
    }

    func unpinMessage(_ message: TDLibKit.Message) {
        guard let client else { return }
        Task {
            do {
                try await client.unpinChatMessage(chatId: message.chatId, messageId: message.id)
                store.removePinnedMessage(chatId: message.chatId, id: message.id)
                loadPinnedMessages(chatId: message.chatId)
            } catch {
                errorMessage = Self.describe(error)
            }
        }
    }

    // MARK: - Usernames

    /// Copies @username of a user, group or channel to the clipboard.
    func copyUsername(for chat: ChatItem) {
        Task {
            guard let username = await username(for: chat) else {
                errorMessage = "У этого чата нет публичного юзернейма"
                return
            }
            UIPasteboard.general.string = "@\(username)"
        }
    }

    private func username(for chat: ChatItem) async -> String? {
        guard let client else { return nil }

        if let userId = chat.privateUserId {
            if let user = store.users[userId] {
                return user.usernames?.activeUsernames.first
            }
            if let user = try? await client.getUser(userId: userId) {
                store.setUser(user)
                return user.usernames?.activeUsernames.first
            }
            return nil
        }

        if case .chatTypeSupergroup(let supergroup) = chat.type {
            if let info = try? await client.getSupergroup(supergroupId: supergroup.supergroupId) {
                return info.usernames?.activeUsernames.first
            }
        }
        return nil
    }

    // MARK: - Phone calls

    /// Opens the system dialer with the contact's number. Telegram does not expose
    /// phone numbers for all users, so the button is shown only when one is known.
    func callUser(userId: Int64, isVideo: Bool = false) {
        // Video calls exist only inside the Telegram media engine.
        if isVideo {
            guard VoIPBridge.engineAvailable() else {
                errorMessage = "Видеозвонки недоступны: встроенный VoIP-движок выключен"
                return
            }
            // The media engine needs real camera access; without it the call
            // would connect with a blank local view.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                Task { await startCall(userId: userId, isVideo: true) }
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    Task { @MainActor in
                        if granted {
                            await self.startCall(userId: userId, isVideo: true)
                        } else {
                            self.errorMessage = "Нет доступа к камере"
                        }
                    }
                }
            default:
                errorMessage = "Нет доступа к камере: разрешите его в Настройках"
            }
            return
        }
        if UserDefaults.standard.bool(forKey: "callViaApp") && VoIPBridge.engineAvailable() {
            Task { await startCall(userId: userId, isVideo: false) }
            return
        }
        if let phone = store.users[userId]?.phoneNumber, !phone.isEmpty {
            call(phoneNumber: "+" + phone)
        } else {
            errorMessage = "Номер телефона недоступен"
        }
    }

    func call(phoneNumber: String) {
        let number = phoneNumber.filter { $0.isNumber || $0 == "+" }
        guard !number.isEmpty, let url = URL(string: "tel:\(number)") else {
            errorMessage = "Не удалось определить номер телефона"
            return
        }
        guard UIApplication.shared.canOpenURL(url) else {
            errorMessage = "Звонки недоступны на этом устройстве"
            return
        }
        UIApplication.shared.open(url)
    }

    // MARK: - Blocking

    /// Loads the main block list so group messages from blocked users can be hidden.
    func loadBlockedUsers() {
        guard let client else { return }
        Task {
            var ids = Set<Int64>()
            var offset = 0
            while offset < 500 {
                guard let page = try? await client.getBlockedMessageSenders(
                    blockList: .blockListMain, limit: 100, offset: offset
                ) else { break }
                for sender in page.senders {
                    if case .messageSenderUser(let user) = sender {
                        ids.insert(user.userId)
                    }
                }
                if page.senders.count < 100 { break }
                offset += page.senders.count
            }
            self.store.setBlockedUsers(ids)
        }
    }

    /// Blocks a user globally. Their messages disappear in every chat, including groups.
    func setUserBlocked(userId: Int64, isBlocked: Bool) {
        guard let client else { return }
        store.setUserBlocked(userId, isBlocked: isBlocked)
        Task {
            do {
                _ = try await client.setMessageSenderBlockList(
                    blockList: isBlocked ? BlockList.blockListMain : nil,
                    senderId: .messageSenderUser(MessageSenderUser(userId: userId))
                )
            } catch {
                self.store.setUserBlocked(userId, isBlocked: !isBlocked)
                self.errorMessage = Self.describe(error)
            }
        }
    }

    // MARK: - Pinning

    /// Pins or unpins a chat in the main list. Optimistic locally, authoritative from TDLib.
    func setPinned(chatId: Int64, isPinned: Bool) {
        guard let client else { return }
        let wasServerPinned = store.chats[chatId]?.isPinned ?? false

        // Local pins are unlimited; server pins (the first N) still sync to Telegram.
        store.setLocallyPinned(chatId: chatId, isPinned: isPinned)
        store.setPinned(chatId: chatId, isPinned: isPinned)

        // A chat that only existed as a local pin needs no unpin request.
        guard isPinned || wasServerPinned else { return }

        Task {
            do {
                _ = try await client.toggleChatIsPinned(
                    chatId: chatId, chatList: .chatListMain, isPinned: isPinned
                )
            } catch {
                if isPinned {
                    // Hit Telegram's pin limit or the network failed: keep the local pin.
                    self.store.setPinned(chatId: chatId, isPinned: false)
                    if !Self.isPinLimitError(error) {
                        self.errorMessage = Self.describe(error)
                    }
                } else {
                    self.store.setPinned(chatId: chatId, isPinned: true)
                    self.store.setLocallyPinned(chatId: chatId, isPinned: true)
                    self.errorMessage = Self.describe(error)
                }
            }
        }
    }

    private static func isPinLimitError(_ error: Swift.Error) -> Bool {
        guard let tdError = error as? TDLibKit.Error else { return false }
        let message = tdError.message.lowercased()
        return message.contains("pinned") ||
            (message.contains("pin") && message.contains("limit")) ||
            message.contains("too many")
    }

    // MARK: - Stickers

    func installedStickerSets() async throws -> [StickerSetInfo] {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.getInstalledStickerSets(stickerType: .stickerTypeRegular).sets
    }

    func stickerSet(id: TdInt64) async throws -> StickerSet {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.getStickerSet(setId: id)
    }

    private func stickerInputFile(_ sticker: Sticker) -> InputFile {
        fileInput(sticker.sticker)
    }

    private func fileInput(_ file: TDLibKit.File) -> InputFile {
        let remoteID = file.remote.id
        return remoteID.isEmpty
            ? .inputFileId(InputFileId(id: file.id))
            : .inputFileRemote(InputFileRemote(id: remoteID))
    }

    func addAnimationToFavoriteSticker(_ animation: TDLibKit.Animation) async throws {
        guard let client else { throw ChatCreationError.notReady }
        _ = try await client.addFavoriteSticker(sticker: fileInput(animation.animation))
    }

    func savedAnimations() async -> [TDLibKit.Animation] {
        guard let client else { return [] }
        return (try? await client.getSavedAnimations().animations) ?? []
    }

    func saveAnimationToTelegram(_ animation: TDLibKit.Animation) async throws {
        guard let client else { throw ChatCreationError.notReady }
        _ = try await client.addSavedAnimation(animation: fileInput(animation.animation))
    }

    func removeSavedAnimation(_ animation: TDLibKit.Animation) async {
        guard let client else { return }
        _ = try? await client.removeSavedAnimation(animation: fileInput(animation.animation))
    }

    func sendAnimation(_ animation: TDLibKit.Animation, to chatId: Int64, replyTo: Int64? = nil) async {
        guard let source = await localFileURL(animation.animation) else {
            errorMessage = "Не удалось скачать гифку"
            return
        }
        let input = InputAnimation(
            addedStickerFileIds: [],
            animation: Self.local(source),
            duration: animation.duration,
            height: animation.height,
            thumbnail: nil,
            width: animation.width
        )
        send(
            .inputMessageAnimation(InputMessageAnimation(
                animation: input,
                caption: nil,
                hasSpoiler: false,
                showCaptionAboveMedia: false
            )),
            to: chatId,
            replyTo: replyTo
        )
    }

    func sendGif(_ gif: SavedGif, to chatId: Int64, replyTo: Int64? = nil) {
        let animation = InputAnimation(
            addedStickerFileIds: [],
            animation: Self.local(GifLibrary.shared.url(for: gif)),
            duration: gif.duration,
            height: gif.height,
            thumbnail: nil,
            width: gif.width
        )
        send(
            .inputMessageAnimation(InputMessageAnimation(
                animation: animation,
                caption: nil,
                hasSpoiler: false,
                showCaptionAboveMedia: false
            )),
            to: chatId,
            replyTo: replyTo
        )
    }

    func sendAnimationAsSticker(
        _ animation: TDLibKit.Animation,
        to chatId: Int64,
        replyTo: Int64? = nil
    ) {
        let sticker = Sticker(
            emoji: "",
            format: .stickerFormatWebm,
            fullType: .stickerFullTypeRegular(StickerFullTypeRegular(premiumAnimation: nil)),
            height: animation.height,
            id: 0,
            setId: 0,
            sticker: animation.animation,
            thumbnail: animation.thumbnail,
            width: animation.width
        )
        sendSticker(sticker, to: chatId, replyTo: replyTo)
    }

    func favoriteStickers() async throws -> [Sticker] {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.getFavoriteStickers().stickers
    }

    func recentStickers() async throws -> [Sticker] {
        guard let client else { throw ChatCreationError.notReady }
        return try await client.getRecentStickers(isAttached: false).stickers
    }

    func addFavoriteSticker(_ sticker: Sticker) async throws {
        guard let client else { throw ChatCreationError.notReady }
        _ = try await client.addFavoriteSticker(sticker: stickerInputFile(sticker))
    }

    func installStickerSet(_ sticker: Sticker) async throws {
        guard let client else { throw ChatCreationError.notReady }
        guard sticker.setId != 0 else { throw ChatCreationError.notReady }
        _ = try await client.changeStickerSet(isArchived: false, isInstalled: true, setId: sticker.setId)
    }

    func recordStickerUsage(_ sticker: Sticker) {
        Task {
            guard let client else { return }
            _ = try? await client.addRecentSticker(isAttached: false, sticker: stickerInputFile(sticker))
        }
    }

    func votePoll(chatId: Int64, messageId: Int64, optionIds: [Int]) {
        guard let client else { return }
        Task {
            do {
                _ = try await client.setPollAnswer(
                    chatId: chatId,
                    messageId: messageId,
                    optionIds: optionIds
                )
            } catch {
                errorMessage = Self.describe(error)
            }
        }
    }

    func sendPoll(
        question: String,
        options: [String],
        anonymous: Bool,
        allowsMultipleAnswers: Bool,
        to chatId: Int64,
        replyTo: Int64? = nil
    ) {
        let cleanOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty, cleanOptions.count >= 2 else { return }

        let poll = InputMessagePoll(
            allowsMultipleAnswers: allowsMultipleAnswers,
            allowsRevoting: false,
            closeDate: 0,
            countryCodes: [],
            description: FormattedText(entities: [], text: ""),
            hideResultsUntilCloses: false,
            isAnonymous: anonymous,
            isClosed: false,
            media: nil,
            membersOnly: false,
            openPeriod: 0,
            options: cleanOptions.map {
                InputPollOption(media: nil, text: FormattedText(entities: [], text: $0))
            },
            question: FormattedText(entities: [], text: cleanQuestion),
            shuffleOptions: false,
            type: .inputPollTypeRegular(InputPollTypeRegular(allowAddingOptions: false))
        )
        send(.inputMessagePoll(poll), to: chatId, replyTo: replyTo)
    }

    func sendSticker(_ sticker: Sticker, to chatId: Int64, replyTo: Int64? = nil) {
        let file = stickerInputFile(sticker)
        let input = InputSticker(
            height: sticker.height,
            sticker: file,
            thumbnail: nil,
            width: sticker.width
        )
        send(
            .inputMessageSticker(InputMessageSticker(emoji: sticker.emoji, sticker: input)),
            to: chatId,
            replyTo: replyTo
        )
    }

    // MARK: - Built-in proxy

    /// Enables TDLib's MTProto proxy pointing at the local WebSocket bridge.
    nonisolated func activateBuiltInProxy(port: Int, secret: String) async throws {
        guard let client = await MainActor.run(resultType: TDLibClient?.self, body: { TelegramClient.shared.client }) else {
            throw ChatCreationError.notReady
        }
        let encoded = "dd" + secret.lowercased()

        let existing = (try? await client.getProxies().proxies) ?? []
        for proxy in existing where proxy.proxy.server == "127.0.0.1" && proxy.proxy.port == port {
            if case .proxyTypeMtproto(let mtproto) = proxy.proxy.type,
               mtproto.secret.lowercased() == encoded {
                try await client.enableProxy(proxyId: proxy.id)
                return
            }
            try? await client.removeProxy(proxyId: proxy.id)
        }

        _ = try await client.addProxy(
            comment: "Встроенный прокси",
            enable: true,
            proxy: Proxy(
                port: port,
                server: "127.0.0.1",
                type: .proxyTypeMtproto(ProxyTypeMtproto(secret: encoded))
            )
        )
    }

    nonisolated func activateExternalProxy(server: String, port: Int, secret: String) async throws {
        guard let client = await MainActor.run(resultType: TDLibClient?.self, body: { TelegramClient.shared.client }) else {
            throw ChatCreationError.notReady
        }
        let cleanServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanServer.isEmpty, (1...65535).contains(port) else {
            throw ChatCreationError.notReady
        }
        var encoded = secret.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !encoded.hasPrefix("dd") {
            encoded = "dd" + encoded
        }
        let existing = (try? await client.getProxies().proxies) ?? []
        for proxy in existing {
            try? await client.removeProxy(proxyId: proxy.id)
        }
        _ = try await client.addProxy(
            comment: "Внешний MTProto-прокси",
            enable: true,
            proxy: Proxy(
                port: port,
                server: cleanServer,
                type: .proxyTypeMtproto(ProxyTypeMtproto(secret: encoded))
            )
        )
    }

    nonisolated func disableAllProxies() async {
        guard let client = await MainActor.run(resultType: TDLibClient?.self, body: { TelegramClient.shared.client }) else { return }
        try? await client.disableProxy()
        if let proxies = try? await client.getProxies().proxies {
            for proxy in proxies {
                try? await client.removeProxy(proxyId: proxy.id)
            }
        }
    }

    /// Disables and removes the local proxy, so TDLib connects directly again.
    nonisolated func deactivateBuiltInProxy(port: Int) async {
        guard let client = await MainActor.run(resultType: TDLibClient?.self, body: { TelegramClient.shared.client }) else { return }
        try? await client.disableProxy()
        guard let proxies = try? await client.getProxies().proxies else { return }
        for proxy in proxies where proxy.proxy.server == "127.0.0.1" && proxy.proxy.port == port {
            try? await client.removeProxy(proxyId: proxy.id)
        }
    }

    // MARK: - Sending

    func send(
        _ content: InputMessageContent,
        to chatId: Int64,
        replyTo: Int64? = nil,
        scheduleDate: Foundation.Date? = nil,
        replyQuote: String? = nil,
        replyQuotePosition: Int = 0
    ) {
        guard let client else { return }
        let quote: InputTextQuote? = replyQuote.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return InputTextQuote(
                position: replyQuotePosition,
                richTexts: [],
                text: FormattedText(entities: [], text: trimmed)
            )
        }
        let reply = replyTo.map {
            InputMessageReplyTo.inputMessageReplyToMessage(
                InputMessageReplyToMessage(checklistTaskId: 0, messageId: $0, pollOptionId: "", quote: quote)
            )
        }
        let options: MessageSendOptions? = scheduleDate.map { date in
            MessageSendOptions(
                allowPaidBroadcast: false,
                disableNotification: false,
                effectId: 0,
                fromBackground: false,
                onlyPreview: false,
                paidMessageStarCount: 0,
                protectContent: false,
                schedulingState: .messageSchedulingStateSendAtDate(
                    MessageSchedulingStateSendAtDate(
                        repeatPeriod: 0,
                        sendDate: Int(date.timeIntervalSince1970)
                    )
                ),
                sendingId: 0,
                suggestedPostInfo: nil,
                updateOrderOfInstalledStickerSets: false
            )
        }
        lastTypingSent[chatId] = nil
        Task {
            do {
                _ = try await client.sendMessage(
                    chatId: chatId, inputMessageContent: content,
                    options: options, replyMarkup: nil, replyTo: reply, topicId: nil
                )
                await self.enforceInvisibleIfNeeded()
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

    func sendText(
        _ text: String,
        to chatId: Int64,
        replyTo: Int64? = nil,
        spoiler: Bool = false,
        scheduleDate: Foundation.Date? = nil,
        replyQuote: String? = nil,
        replyQuotePosition: Int = 0
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entities: [TextEntity] = spoiler
            ? [TextEntity(
                length: trimmed.utf16.count,
                offset: 0,
                type: .textEntityTypeSpoiler
            )]
            : []
        let formatted = FormattedText(entities: entities, text: trimmed)
        send(
            .inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: formatted)),
            to: chatId,
            replyTo: replyTo,
            scheduleDate: scheduleDate,
            replyQuote: replyQuote,
            replyQuotePosition: replyQuotePosition
        )
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

    /// Sends library tracks to another chat as audio messages (albums of up to 10).
    func sendTracks(_ tracks: [MusicTrack], to chatId: Int64) async {
        guard let client, !tracks.isEmpty else { return }
        let contents: [InputMessageContent] = tracks.map { track in
            let audio = InputAudio(
                albumCoverThumbnail: nil,
                audio: Self.local(MusicLibrary.shared.url(for: track)),
                duration: track.duration ?? 0,
                performer: track.artist,
                title: track.title
            )
            return .inputMessageAudio(InputMessageAudio(audio: audio, caption: nil))
        }

        do {
            var index = 0
            while index < contents.count {
                let end = min(index + 10, contents.count)
                let chunk = Array(contents[index..<end])
                if chunk.count == 1 {
                    _ = try await client.sendMessage(
                        chatId: chatId,
                        inputMessageContent: chunk[0],
                        options: nil,
                        replyMarkup: nil,
                        replyTo: nil,
                        topicId: nil
                    )
                } else {
                    _ = try await client.sendMessageAlbum(
                        chatId: chatId,
                        inputMessageContents: chunk,
                        options: nil,
                        replyTo: nil,
                        topicId: nil
                    )
                }
                index = end
            }
        } catch {
            errorMessage = "Не удалось отправить треки: \(Self.describe(error))"
        }
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
        let anonymous = UserDefaults.standard.object(forKey: "anonymousForwarding") as? Bool ?? true
        guard anonymous else {
            perform {
                _ = try await $0.forwardMessages(
                    chatId: chatId, fromChatId: message.chatId, messageIds: [message.id],
                    options: nil, removeCaption: false, sendCopy: false, topicId: nil
                )
            }
            return
        }
        Task { await forwardAnonymously(message, to: chatId) }
    }

    private func forwardAnonymously(_ message: Message, to chatId: Int64) async {
        let caption = MessageFormatter.caption(of: message.content)?.text ?? ""
        switch message.content {
        case .messageText, .messageAnimation:
            if case .messageAnimation(let animation) = message.content,
               let source = await localFileURL(animation.animation.animation) {
                let input = InputAnimation(
                    addedStickerFileIds: [], animation: Self.local(source),
                    duration: animation.animation.duration,
                    height: animation.animation.height,
                    thumbnail: nil, width: animation.animation.width
                )
                send(.inputMessageAnimation(InputMessageAnimation(
                    animation: input, caption: Self.captionText(caption),
                    hasSpoiler: false, showCaptionAboveMedia: false
                )), to: chatId)
            } else if !caption.isEmpty {
                sendText(caption, to: chatId)
            }
        case .messagePhoto(let photo):
            guard let size = photo.photo.sizes.last,
                  let source = await localFileURL(size.photo) else { return }
            sendPhoto(source, width: size.width, height: size.height, caption: caption, to: chatId, replyTo: nil)
        case .messageVideo(let video):
            guard let source = await localFileURL(video.video.video) else { return }
            sendVideo(source, width: video.video.width, height: video.video.height,
                      duration: video.video.duration, caption: caption, to: chatId, replyTo: nil)
        case .messageDocument(let document):
            guard let source = await localFileURL(document.document.document) else { return }
            sendDocument(source, caption: caption, to: chatId, replyTo: nil)
        case .messageSticker(let sticker):
            sendSticker(sticker.sticker, to: chatId)
        default:
            if !caption.isEmpty { sendText(caption, to: chatId) }
        }
    }

    /// Read-only storage statistics from TDLib; never deletes anything.
    func storageStatisticsSummary() async -> String? {
        guard let client, let stats = try? await client.getStorageStatistics(chatLimit: 20) else {
            return nil
        }
        return "\(stats.count) файлов, \(MessageFormatter.fileSize(stats.size))"
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

    /// Returns a local URL, downloading the file synchronously if necessary.
    private func beginDownloadBackgroundTask() {
        guard downloadBackgroundTask == .invalid else { return }
        downloadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FignyagramDownload") { [weak self] in
            self?.endDownloadBackgroundTask()
        }
    }

    private func endDownloadBackgroundTask() {
        guard downloadBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(downloadBackgroundTask)
        downloadBackgroundTask = .invalid
    }

    nonisolated func localFileURL(_ file: File) async -> URL? {
        if let path = await MainActor.run(resultType: String?.self, body: { FileStore.shared.localPath(file) }) {
            return URL(fileURLWithPath: path)
        }
        guard let client = await MainActor.run(resultType: TDLibClient?.self, body: { TelegramClient.shared.client }) else { return nil }
        if let downloaded = try? await client.downloadFile(
            fileId: file.id, limit: 0, offset: 0, priority: 32, synchronous: true
        ) {
            await MainActor.run { FileStore.shared.update(downloaded) }
            if let path = await MainActor.run(resultType: String?.self, body: { FileStore.shared.localPath(downloaded) }) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func download(_ file: File, priority: Int = 1) {
        guard let client else { return }
        let current = FileStore.shared.latest(file)
        guard current.local.canBeDownloaded,
              !current.local.isDownloadingCompleted,
              !current.local.isDownloadingActive,
              !requestedDownloads.contains(file.id) else { return }
        requestedDownloads.insert(file.id)
        beginDownloadBackgroundTask()
        activeDownloadCount += 1
        Task {
            defer {
                self.activeDownloadCount = max(0, self.activeDownloadCount - 1)
                if self.activeDownloadCount == 0 { self.endDownloadBackgroundTask() }
            }
            if let updated = try? await client.downloadFile(
                fileId: file.id, limit: 0, offset: 0, priority: priority, synchronous: false
            ) {
                FileStore.shared.update(updated)
            } else {
                self.requestedDownloads.remove(file.id)
            }
        }
    }
}
