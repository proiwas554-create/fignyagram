import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import TDLibKit

struct ChatView: View {
    let chatId: Int64
    /// When opened from search, the message to reveal and scroll to.
    var focusMessageId: Int64? = nil

    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var limits = DisplayLimits.shared
    @ObservedObject private var performance = PerformanceMode.shared
    @ObservedObject private var musicPlayer = MusicPlayer.shared
    @ObservedObject private var aliases = LocalAliases.shared
    @StateObject private var voice = VoiceRecorder()

    @State private var text = ""
    @State private var didInitialScroll = false
    @State private var olderAnchorId: Int64?
    @State private var scrollTarget: Int64?
    @State private var showSearch = false
    @State private var showNotifications = false
    @State private var showStickers = false
    @State private var showMedia = false
    @State private var didFocusInitialMessage = false

    /// User is looking at the newest message, so incoming messages may auto-scroll.
    @State private var isAtBottom = true
    /// A message was received while the user was reading history; shown on the button.
    @State private var unseenWhileScrolledUp = 0
    @State private var previousLastMessageId: Int64?
    @State private var extraMessages = 0

    @State private var replyTo: TDLibKit.Message?
    @State private var editing: TDLibKit.Message?
    @State private var actionMessage: TDLibKit.Message?
    @State private var forwardMessage: TDLibKit.Message?
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var showVideoNoteRecorder = false
    @State private var preparingMedia = 0
    @State private var composerPayload: MediaComposerPayload?
    @AppStorage("autoTextFileThreshold") private var autoTextFileThreshold = 0
    @State private var showPollComposer = false
    @State private var showAttachmentDialog = false
    @AppStorage("messageListCollection") private var useCollectionMessageList = false
    @State private var sendMediaAsFiles = false
    @State private var registeredChatPresentation = false
    @State private var showScheduleComposer = false
    @State private var pendingAttachmentAction: AttachmentAction?
    @ObservedObject private var ultra = UltraMode.shared
    @ObservedObject private var classic = ClassicDesignMode.shared
    @State private var showPinned = false
    @State private var showChatInfo = false
    @State private var repliesMessage: TDLibKit.Message?
    @State private var showRepliesToMe = false
    @State private var seenReplyIDs: Set<Int64> = []
    @AppStorage("disableAutoScroll") private var disableAutoScroll = false
    @ObservedObject private var drafts = DraftStore.shared
    @State private var mentionSuggestions: [TelegramClient.UsernameSuggestion] = []
    @State private var mentionTask: Task<Void, Never>?
    @State private var mentionQuery = ""
    @FocusState private var isInputFocused: Bool
    @State private var sendAsSpoiler = false
    @State private var tagUserId: Int64?
    @State private var quoteMessage: TDLibKit.Message?
    @State private var translationTarget: TranslationTarget?
    @State private var showRoundVideoPicker = false
    @State private var appleTranslateText: AppleTranslationTarget?
    @State private var showEncryptPrompt = false
    @State private var decryptRequest: DecryptRequest?
    @State private var decryptedNote: DecryptedNote?
    @State private var summaryText: String?
    @State private var showSummary = false
    @ObservedObject private var snippets = SnippetsStore.shared
    @State private var replyQuote: String?
    @State private var replyQuotePosition = 0
    @State private var previewStickerSetId: TdInt64?
    @State private var shareItem: ShareItem?
    @State private var saveAlertText = ""
    @State private var showSaveAlert = false
    @State private var stickerSaveBusy = false
    @State private var taggedChatId: Int64?
    @State private var linkedChatId: Int64?

    /// Invisible anchor at the end of the list; scrolling to it always reaches the bottom.
    private static let bottomAnchor = "chat-bottom"
    /// Coordinate space used to measure how far the bottom anchor is from the viewport.
    private static let scrollSpace = "chat-scroll"

    private var chat: ChatItem? { store.chats[chatId] }
    private var messages: [TDLibKit.Message] { store.messages[chatId] ?? [] }
    private var isLoading: Bool { store.loadingChats.contains(chatId) }

    /// Messages from globally blocked users are hidden everywhere.
    private var unblockedMessages: [TDLibKit.Message] {
        messages.filter { !store.isSenderBlocked($0.senderId) }
    }

    /// Only the newest N unblocked messages are rendered; the rest stay in memory
    /// and can be revealed with the "Показать ещё" button.
    private var visibleMessages: [TDLibKit.Message] {
        let limit = max(1, limits.effectiveMessagesPerChat + extraMessages)
        let source = unblockedMessages
        guard source.count > limit else { return source }
        return Array(source.suffix(limit))
    }

    /// Whether this chat has an explicit mute that overrides the chat-type settings.
    private var notificationsMuted: Bool {
        guard let settings = chat?.notificationSettings, !settings.useDefaultMuteFor else { return false }
        return settings.muteFor > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pinned = store.pinnedMessages(chatId: chatId).first {
                pinnedBanner(pinned)
                Divider()
            }
            if useCollectionMessageList {
                collectionMessageListView
            } else {
                messageList
            }
            if let error = client.errorMessage {
                ErrorBanner(message: error)
                    .padding(.vertical, 4)
                    .onTapGesture { client.errorMessage = nil }
            }
            if let userId = chat?.privateUserId, chat?.blockList == .blockListMain {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "nosign").foregroundColor(.secondary)
                    Text("Пользователь заблокирован")
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Разблокировать") {
                        client.setUserBlocked(userId: userId, isBlocked: false)
                    }
                    .font(.appFootnote)
                }
                .padding(10)
            } else if store.canWrite(chatId: chatId) {
                if !mentionSuggestions.isEmpty {
                    mentionSuggestionsView
                }
                Divider()
                inputArea
            } else if chat?.isChannel == true {
                Divider()
                Text("Публиковать в этом канале могут только администраторы")
                    .font(.appFootnote).foregroundColor(.secondary)
                    .padding(10)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if musicPlayer.current != nil {
                GlobalPlayerBar()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .modifier(HidesTabBar())
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showChatInfo = true
                } label: {
                    VStack(spacing: 0) {
                        Text(aliases.chatAlias(chatId) ?? chat?.title ?? "Чат").font(.appHeadline).lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.appCaption2)
                                .foregroundColor(store.actionText(chatId: chatId) != nil ? .accentColor : .secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !ultra.isEnabled {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .classicIconButton()
                }
                .accessibilityLabel("Поиск в чате")

                Menu {
                    Button {
                        summaryText = ConversationSummary.summarize(messages: Array(visibleMessages.suffix(120)))
                        showSummary = true
                    } label: {
                        Label("Кратко о переписке", systemImage: "text.append")
                    }
                    Button {
                        let texts = visibleMessages.suffix(120).compactMap { message -> String? in
                            if case .messageText(let text) = message.content, !text.text.text.isEmpty {
                                return text.text.text
                            }
                            return nil
                        }
                        summaryText = AIContextManager.summarize(messages: Array(texts))
                        showSummary = true
                    } label: {
                        Label("AI-выжимка (на устройстве)", systemImage: "brain")
                    }
                    Button {
                        showChatInfo = true
                    } label: {
                        Label("Информация о чате", systemImage: "info.circle")
                    }
                    Button {
                        showMedia = true
                    } label: {
                        Label("Медиа и файлы", systemImage: "folder")
                    }
                    Button {
                        showNotifications = true
                    } label: {
                        Label(
                            notificationsMuted ? "Включить уведомления" : "Настроить уведомления",
                            systemImage: notificationsMuted ? "bell" : "bell.slash"
                        )
                    }
                    if !repliesToMe.isEmpty {
                        Button {
                            showRepliesToMe = true
                        } label: {
                            Label("История ответов мне", systemImage: "at")
                        }
                    }
                    if let linkedChatId {
                        Button {
                            taggedChatId = linkedChatId
                        } label: {
                            Label("Перейти в обсуждение", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .classicIconButton()
                }
                .accessibilityLabel("Ещё")
                }
            }
        }
        .modifier(HideTabBarModifier())
        .onAppear {
            loadDraft()
            loadSeenReplies()
            if !registeredChatPresentation {
                registeredChatPresentation = true
                ChatPresentationState.shared.enter()
            }
            client.openChat(chatId)
            if let userId = chat?.privateUserId {
                RecentContactsStore.shared.record(userId)
                ContactsSync.shared.scheduleSync()
            }
            ChatStore.shared.applyDeletedArchive(chatId: chatId)
            focusOnSearchResultIfNeeded()
        }
        .onDisappear {
            dismissKeyboard()
            if registeredChatPresentation {
                registeredChatPresentation = false
                ChatPresentationState.shared.leave()
            }
        }
        .task(id: chatId) {
            linkedChatId = await client.linkedChatId(for: chatId)
            await client.prefetchMemberTags(chatId: chatId)
        }
        .environment(\.openURL, OpenURLAction { url in
            if handleInternalLink(url) {
                return .handled
            }
            return .systemAction
        })
        .background(
            NavigationLink(
                destination: Group {
                    if let taggedChatId {
                        ChatView(chatId: taggedChatId)
                    }
                },
                isActive: Binding(
                    get: { taggedChatId != nil },
                    set: { if !$0 { taggedChatId = nil } }
                )
            ) { EmptyView() }
            .hidden()
        )
        .onDisappear {
            client.closeChat(chatId)
            if voice.isRecording { voice.cancel() }
            // Never tear down the shared audio session while music is playing.
            if MusicPlayer.shared.current == nil {
                AudioPlayback.shared.stop()
            }
        }
        .sheet(item: Binding(get: { actionMessage.map(Identified.init) }, set: { actionMessage = $0?.message })) { item in
            MessageActionsSheet(message: item.message) { handle($0, for: item.message) }
        }
        .sheet(item: Binding(get: { forwardMessage.map(Identified.init) }, set: { forwardMessage = $0?.message })) { item in
            ChatPickerView(title: "Переслать") { target in
                client.forward(item.message, to: target)
            }
        }
        .sheet(isPresented: $showRoundVideoPicker) {
            RoundVideoPicker { url in
                sendRoundVideo(url)
            }
        }
        .sheet(isPresented: $showEncryptPrompt) {
            PassphrasePrompt(title: "Ключ шифрования") { key in
                sendEncryptedNote(key: key)
            }
        }
        .sheet(item: $decryptRequest) { request in
            PassphrasePrompt(title: "Ключ для расшифровки") { key in
                decryptNote(request, key: key)
            }
        }
        .sheet(isPresented: $showSummary) {
            NavigationView {
                ScrollView {
                    Text((summaryText ?? "").isEmpty ? "Недостаточно текста для выжимки." : (summaryText ?? ""))
                        .font(.appBody)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Кратко")
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: $decryptedNote) { note in
            NavigationView {
                ScrollView {
                    Text(note.text)
                        .font(.appBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Расшифрованная заметка")
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: $appleTranslateText) { target in
            if #available(iOS 18.0, *) {
                AppleTranslateSheet(text: target.text)
            }
        }
        .sheet(isPresented: $showAttachmentDialog, onDismiss: applyPendingAttachment) {
            AttachmentMenuView(spoilerEnabled: sendAsSpoiler, compact: ultra.isEnabled) { action in
                pendingAttachmentAction = action
            }
        }
        .sheet(isPresented: $showScheduleComposer) {
            ScheduleMessageView(text: $text) { date in
                sendScheduledText(at: date)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { providers in preparePicked(providers) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { urls in prepareDocuments(urls) }.ignoresSafeArea()
        }
        .sheet(item: $composerPayload) { payload in
            MediaComposerView(items: payload.items, initialCaption: payload.caption) { caption, media in
                sendPreparedMedia(caption: caption, media: media)
            }
        }
        .sheet(isPresented: $showPollComposer) {
            PollComposerView { question, options, anonymous, multiple in
                client.sendPoll(
                    question: question,
                    options: options,
                    anonymous: anonymous,
                    allowsMultipleAnswers: multiple,
                    to: chatId,
                    replyTo: takeReply()
                )
            }
        }
        .sheet(isPresented: $showPinned) {
            PinnedMessagesView(chatId: chatId) { messageId in
                jump(to: messageId)
            }
        }
        .sheet(isPresented: $showChatInfo) {
            PeerInfoView(chatId: chatId)
        }
        .sheet(item: Binding(
            get: { previewStickerSetId.map(IdentifiedTdInt.init) },
            set: { previewStickerSetId = $0?.value }
        )) { target in
            StickerSetView(setId: target.value, chatId: chatId)
        }
        .sheet(item: Binding(
            get: { tagUserId.map(IdentifiedInt.init) },
            set: { tagUserId = $0?.value }
        )) { target in
            MemberTagView(chatId: chatId, userId: target.value)
        }
        .sheet(item: $translationTarget) { target in
            TranslationSheet(text: target.text)
        }
        .sheet(item: Binding(
            get: { quoteMessage.map(Identified.init) },
            set: { quoteMessage = $0?.message }
        )) { item in
            QuoteSelectionView(text: MessageFormatter.caption(of: item.message.content)?.text ?? "") { quote, position in
                replyTo = item.message
                replyQuote = quote
                replyQuotePosition = position
                isInputFocused = true
            }
        }
        .sheet(isPresented: $showRepliesToMe) {
            RepliesToMeView(chatId: chatId, replies: repliesToMe) { messageId in
                jump(to: messageId)
            }
        }
        .sheet(item: Binding(get: { repliesMessage.map(Identified.init) }, set: { repliesMessage = $0?.message })) { item in
            MessageRepliesView(chatId: chatId, messageId: item.message.id) { messageId in
                jump(to: messageId)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert("Готово", isPresented: $showSaveAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveAlertText)
        }
        .fullScreenCover(isPresented: $showVideoNoteRecorder) {
            VideoNoteRecorderView { prepared in
                client.sendVideoNote(prepared.url, duration: prepared.duration, length: prepared.width, to: chatId, replyTo: takeReply())
            }
        }
        .sheet(isPresented: $showSearch) { searchSheet }
        .sheet(isPresented: $showNotifications) { notificationsSheet }
        .sheet(isPresented: $showStickers) { stickersSheet }
        .sheet(isPresented: $showMedia) {
            ChatMediaView(chatId: chatId) { messageId in
                jump(to: messageId)
            }
        }
    }

    private var searchSheet: some View {
        ChatSearchView(chatId: chatId, title: chat?.title ?? "Поиск") { messageId in
            jump(to: messageId)
        }
    }

    private var notificationsSheet: some View {
        ChatNotificationSettingsView(chatId: chatId)
    }

    private var stickersSheet: some View {
        StickerPickerView(chatId: chatId)
    }

    private func shouldShowSender(_ message: TDLibKit.Message) -> Bool {
        guard chat?.isGroup == true else { return false }
        guard let index = messages.firstIndex(where: { $0.id == message.id }), index > 0 else {
            return true
        }
        let previous = messages[index - 1]
        if previous.senderId != message.senderId { return true }
        if MessageFormatter.serviceText(previous.content) != nil { return true }
        if message.date - previous.date > 300 { return true }
        return false
    }

    private var repliesToMe: [TDLibKit.Message] {
        guard let myId = client.me?.id else { return [] }
        return messages.filter { message in
            guard !message.isOutgoing,
                  case .messageReplyToMessage(let reply) = message.replyTo else { return false }
            let originalChat = reply.chatId == 0 ? chatId : reply.chatId
            guard let original = store.message(chatId: originalChat, id: reply.messageId) else { return false }
            if original.isOutgoing { return true }
            if case .messageSenderUser(let sender) = original.senderId {
                return sender.userId == myId
            }
            return false
        }
    }

    private var unseenRepliesToMe: [TDLibKit.Message] {
        repliesToMe.filter { !seenReplyIDs.contains($0.id) }
    }

    private var seenRepliesKey: String { "seenReplies_\(chatId)" }

    private func loadSeenReplies() {
        let values = UserDefaults.standard.array(forKey: seenRepliesKey) as? [Int64] ?? []
        seenReplyIDs = Set(values)
    }

    private func markRepliesSeen() {
        seenReplyIDs.formUnion(repliesToMe.map(\.id))
        UserDefaults.standard.set(Array(seenReplyIDs), forKey: seenRepliesKey)
    }

    // MARK: - Messages

    @State private var headerDateText: String?

    private func isFirstMessageOfDay(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = visibleMessages[index]
        let previous = visibleMessages[index - 1]
        let a = Date(timeIntervalSince1970: TimeInterval(current.date))
        let b = Date(timeIntervalSince1970: TimeInterval(previous.date))
        return !Calendar.current.isDate(a, inSameDayAs: b)
    }

    @ViewBuilder
    private func dayHeader(for date: Foundation.Date) -> some View {
        Text(Self.dayHeaderFormatter.string(from: date))
            .font(.appCaption.bold())
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
            .padding(.vertical, 6)
            .onAppear {
                let text = Self.dayHeaderFormatter.string(from: date)
                if headerDateText != text {
                    withAnimation(.easeInOut(duration: 0.15)) { headerDateText = text }
                }
            }
    }

    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM, EEEE"
        return f
    }()

    // MARK: - Collection-backed message list

    private var collectionMessageEntries: [CollectionMessageList.Entry] {
        var result: [CollectionMessageList.Entry] = []
        let list = visibleMessages
        for (index, message) in list.enumerated() {
            if isFirstMessageOfDay(at: index) {
                result.append(.init(id: "d-\(message.id)", kind: .day(TimeInterval(message.date))))
            }
            result.append(.init(id: "m-\(message.id)", kind: .message(message)))
        }
        return result
    }

    private var collectionMessageListView: some View {
        CollectionMessageList(
            entries: collectionMessageEntries,
            scrollTarget: scrollTarget,
            onScrollTargetHandled: { scrollTarget = nil },
            onReachTop: {
                if visibleMessages.count < unblockedMessages.count {
                    extraMessages += limits.effectiveMessagesPerChat
                } else if !store.fullyLoadedChats.contains(chatId) {
                    olderAnchorId = messages.first?.id
                    client.loadOlderMessages(chatId: chatId)
                }
            },
            makeRow: { message in
                AnyView(
                    MessageRow(
                        message: message,
                        showSender: shouldShowSender(message),
                        isRead: message.id <= (chat?.lastReadOutboxMessageId ?? 0),
                        senderName: store.senderName(message.senderId),
                        forwardedFrom: message.forwardInfo.map { store.originName($0.origin) },
                        onReply: { startReply(message) },
                        onLongPress: { actionMessage = message },
                        onReplyTap: { scrollTarget = $0 },
                        onSenderTap: { openSender($0) },
                        onOpenReplies: { repliesMessage = message },
                        onRetry: { client.resendMessage(chatId: message.chatId, messageId: message.id) }
                    )
                )
            }
        )
    }

    private var earlierButtonTitle: String {
        "Показать ещё \(min(limits.effectiveMessagesPerChat, unblockedMessages.count - visibleMessages.count))"
    }

    @ViewBuilder
    private func messageRowCell(_ message: Message) -> some View {
        let index = visibleMessages.firstIndex(where: { $0.id == message.id }) ?? 0
        VStack(alignment: .leading, spacing: 4) {
            if isFirstMessageOfDay(at: index) {
                dayHeader(for: Date(timeIntervalSince1970: TimeInterval(message.date)))
            }
            MessageRow(
                message: message,
                showSender: shouldShowSender(message),
                isRead: message.id <= (chat?.lastReadOutboxMessageId ?? 0),
                senderName: store.senderName(message.senderId),
                forwardedFrom: message.forwardInfo.map { store.originName($0.origin) },
                onReply: { startReply(message) },
                onLongPress: { actionMessage = message },
                onReplyTap: { scrollTarget = $0 },
                onSenderTap: { openSender($0) },
                onOpenReplies: { repliesMessage = message },
                onRetry: { client.resendMessage(chatId: message.chatId, messageId: message.id) }
            )
            .equatable()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            List {
                if visibleMessages.count < unblockedMessages.count {
                    Button {
                        extraMessages += limits.effectiveMessagesPerChat
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.up")
                            Text("Показать ещё \(min(limits.effectiveMessagesPerChat, unblockedMessages.count - visibleMessages.count))")
                        }
                        .font(.appFootnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if !messages.isEmpty && !store.fullyLoadedChats.contains(chatId) {
                    ProgressView()
                        .padding()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .onAppear {
                            olderAnchorId = messages.first?.id
                            client.loadOlderMessages(chatId: chatId)
                        }
                }
                ForEach(visibleMessages, id: \.id) { message in
                    messageRowCell(message)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id(message.id)
                }

                // Bottom marker: drives the "jump to latest" button without a
                // per-frame geometry observer, which invalidated the whole list.
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchor)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onAppear {
                        if !isAtBottom {
                            isAtBottom = true
                            unseenWhileScrolledUp = 0
                        }
                    }
                    .onDisappear {
                        if isAtBottom { isAtBottom = false }
                    }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
                .coordinateSpace(name: Self.scrollSpace)
                .overlay(alignment: .top) {
                    if let text = headerDateText, !isAtBottom {
                        Text(text)
                            .font(.appCaption.bold())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.regularMaterial))
                            .padding(.top, 6)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if messages.isEmpty || unblockedMessages.isEmpty {
                        if isLoading {
                            ProgressView("Загрузка…")
                        } else if !messages.isEmpty {
                            Text("Сообщения скрыты").foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 12) {
                                Text("Сообщений нет").foregroundColor(.secondary)
                                Button("Обновить") { client.loadHistory(chatId: chatId) }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .onChange(of: isAtBottom) { atBottom in
                    if atBottom { unseenWhileScrolledUp = 0 }
                }
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 8) {
                        if !unseenRepliesToMe.isEmpty {
                            Button {
                                markRepliesSeen()
                                showRepliesToMe = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Circle()
                                        .fill(.clear)
                                        .background(GlassBackgroundView(cornerRadius: 21))
                                        .frame(width: 42, height: 42)
                                    Image(systemName: "at")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                        .frame(width: 42, height: 42)
                                    if unseenRepliesToMe.count > 1 {
                                        Text("\(min(unseenRepliesToMe.count, 99))")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.red))
                                            .offset(x: 3, y: -2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Ответы на мои сообщения")
                        }
                        if !isAtBottom && didInitialScroll {
                            scrollDownButton(proxy)
                                .transition(.scale(scale: 0.7).combined(with: .opacity))
                        }
                    }
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                }
                .onAppear {
                    // Wait for the first LazyVStack layout, otherwise scrollTo may miss the anchor.
                    DispatchQueue.main.async {
                        previousLastMessageId = messages.last?.id
                        didInitialScroll = true
                        // A search result should win over the usual "jump to latest".
                        if focusMessageId == nil {
                            scrollToBottom(proxy, animated: false)
                        }
                    }
                }
                .onChange(of: messages.last?.id) { newValue in
                    let oldId = previousLastMessageId
                    previousLastMessageId = newValue

                    guard didInitialScroll else {
                        guard newValue != nil else { return }
                        scrollToBottom(proxy, animated: false)
                        didInitialScroll = true
                        return
                    }
                    // Deletions and other reloads can move the last id backwards; ignore those.
                    guard let newId = newValue else { return }
                    if let oldId = oldId, newId <= oldId { return }
                    if let last = messages.last, store.isSenderBlocked(last.senderId) { return }

                    if disableAutoScroll {
                        unseenWhileScrolledUp += 1
                    } else if messages.last?.isOutgoing == true || isAtBottom {
                        scrollToBottom(proxy, animated: true)
                        unseenWhileScrolledUp = 0
                    } else {
                        // The user is reading history: don't yank the list, badge the button instead.
                        unseenWhileScrolledUp += 1
                    }
                }
                .onChange(of: limits.effectiveMessagesPerChat) { _ in extraMessages = 0 }
                .onChange(of: messages.first?.id) { _ in
                    if let anchor = olderAnchorId {
                        if visibleMessages.contains(where: { $0.id == anchor }) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                        olderAnchorId = nil
                    }
                }
                .onChange(of: scrollTarget) { target in
                    guard let target else { return }
                    if visibleMessages.contains(where: { $0.id == target }) {
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                    } else if let blocked = messages.first(where: { $0.id == target }),
                              store.isSenderBlocked(blocked.senderId) {
                        client.errorMessage = "Автор этого сообщения заблокирован"
                    } else if messages.contains(where: { $0.id == target }) {
                        // The message is loaded but outside the rendered window.
                        expandWindow(to: target)
                        scrollTarget = nil
                        DispatchQueue.main.async { scrollTarget = target }
                        return
                    } else {
                        client.errorMessage = "Сообщение ещё не загружено — пролистайте выше"
                    }
                    scrollTarget = nil
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { isInputFocused = false })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            if value.translation.height > 16, isAtBottom {
                                isAtBottom = false
                            }
                        }
                )
        }
    }

    /// Floating "jump to latest" button, like the one in the official clients.
    private func scrollDownButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            unseenWhileScrolledUp = 0
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            // Fallback for older iOS versions if the anchor isn't materialised yet.
            if let last = visibleMessages.last?.id {
                DispatchQueue.main.async {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(.clear)
                    .background(GlassBackgroundView(cornerRadius: 21))
                    .frame(width: 42, height: 42)
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .overlay(alignment: .topTrailing) {
                if unseenWhileScrolledUp > 0 {
                    Text(unseenWhileScrolledUp > 99 ? "99+" : "\(unseenWhileScrolledUp)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 6, y: -6)
                }
            }
            .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Прокрутить к последним сообщениям")
    }

    // MARK: - Input

    @ViewBuilder
    private var inputArea: some View {
        VStack(spacing: 0) {
            if let banner = bannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: editing != nil ? "pencil" : "arrowshape.turn.up.left")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(editing != nil ? "Редактирование" : store.senderName(banner.senderId))
                            .font(.caption.bold()).foregroundColor(.accentColor)
                        Text(MessageFormatter.preview(banner.content)).font(.appCaption).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        if editing != nil { text = "" }
                        replyTo = nil
                        editing = nil
                    } label: {
                        Image(systemName: "xmark").foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            if voice.isRecording {
                recordingBar
            } else {
                inputBar
            }
        }
        .glassPanel(cornerRadius: 24)
    }

    private var bannerMessage: TDLibKit.Message? { editing ?? replyTo }

    private var mentionSuggestionsView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(mentionSuggestions) { suggestion in
                    HStack(spacing: 8) {
                        Button {
                            insertMention(suggestion)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: suggestion.isBot ? "cpu" : "at")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("@\(suggestion.username)")
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                    if !suggestion.title.isEmpty {
                                        Text(suggestion.title)
                                            .font(.appCaption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if suggestion.isBot {
                            Button("Открыть") {
                                openBot(suggestion)
                            }
                            .font(.appCaption)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 170)
        .background(.thinMaterial)
    }

    private func scheduleMentionSuggestions(for value: String) {
        mentionTask?.cancel()
        guard editing == nil,
              let last = value.split(separator: " ", omittingEmptySubsequences: false).last,
              last.hasPrefix("@"), last.count > 1 else {
            mentionSuggestions = []
            mentionQuery = ""
            return
        }
        let query = String(last.dropFirst())
        mentionQuery = query
        mentionTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let suggestions = await client.usernameSuggestions(query)
            guard !Task.isCancelled, query == mentionQuery else { return }
            mentionSuggestions = suggestions
        }
    }

    private func insertMention(_ suggestion: TelegramClient.UsernameSuggestion) {
        let token = "@\(mentionQuery)"
        if let range = text.range(of: token, options: .backwards) {
            text.replaceSubrange(range, with: "@\(suggestion.username) ")
        }
        mentionSuggestions = []
        mentionQuery = ""
    }

    private func openBot(_ suggestion: TelegramClient.UsernameSuggestion) {
        Task {
            if let id = await client.resolveUsername(suggestion.username) {
                taggedChatId = id
                mentionSuggestions = []
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !text.isEmpty && editing == nil {
                Button {
                    sendTextAsFile()
                } label: {
                    Image(systemName: "doc.text")
                        .font(.system(size: 20))
                        .classicIconButton()
                }
                .accessibilityLabel("Отправить текст файлом")
            }
            if editing == nil && !text.isEmpty {
                Menu {
                    Button("Перевернуть") { text = TextTransformers.reversed(text) }
                    Button("SpongeBob") { text = TextTransformers.spongebob(text) }
                    Button("Убрать лишние пробелы") { text = TextTransformers.collapsedSpaces(text) }
                    Button("Зашифровать и отправить") { showEncryptPrompt = true }
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 19))
                        .classicIconButton()
                }
                .accessibilityLabel("Трансформировать текст")
            }
            if editing == nil {
                Button {
                    showRoundVideoPicker = true
                } label: {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 20))
                        .classicIconButton()
                }
                .accessibilityLabel("Кружок из галереи")
            }
            if editing == nil {
                Button {
                    showAttachmentDialog = true
                } label: {
                    Group {
                        if preparingMedia > 0 {
                            ProgressView()
                        } else {
                            Image(systemName: "paperclip")
                                .font(.system(size: 22))
                                .classicIconButton()
                        }
                    }
                    .frame(width: 38, height: 38)
                }
                .accessibilityLabel("Вложения")
            }

            Group {
                if #available(iOS 16.0, *) {
                    TextField("Сообщение", text: $text, axis: .vertical).lineLimit(1...5)
                } else {
                    TextField("Сообщение", text: $text)
                }
            }
            .focused($isInputFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: classic.isEnabled ? 14 : 22).fill(Color(.secondarySystemBackground)))
            .contextMenu {
                ForEach(snippets.snippets, id: \.self) { snippet in
                    Button(snippet) { text = snippet }
                }
                if !snippets.snippets.isEmpty {
                    Divider()
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Сохранить как шаблон") {
                        snippets.add(text)
                    }
                }
            }
            .onChange(of: text) { newValue in
                if !newValue.isEmpty && editing == nil { client.sendChatAction(.chatActionTyping, chatId: chatId) }
                if editing == nil { drafts.save(newValue, for: chatId) }
                scheduleMentionSuggestions(for: newValue)
            }

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editing != nil {
                Button(action: sendText) {
                    Image(systemName: editing != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
            } else {
                Button(action: startVoice) {
                    Image(systemName: "mic")
                        .font(.system(size: 22))
                        .classicIconButton()
                        .frame(width: 38, height: 38)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
                .scaleEffect(1 + CGFloat(voice.level) * 0.6)
            Text(MessageFormatter.duration(Int(voice.elapsed))).monospacedDigit()
            Spacer()
            Button("Отмена", role: .destructive) {
                voice.cancel()
                client.sendChatAction(.chatActionCancel, chatId: chatId)
            }
            Button {
                if let recording = voice.stop() {
                    client.sendVoiceNote(recording.url, duration: recording.duration, waveform: recording.waveform, to: chatId, replyTo: takeReply())
                } else {
                    client.sendChatAction(.chatActionCancel, chatId: chatId)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func applyPendingAttachment() {
        guard let action = pendingAttachmentAction else { return }
        pendingAttachmentAction = nil
        switch action {
        case .photo:
            sendMediaAsFiles = false
            showPhotoPicker = true
        case .photoFile:
            sendMediaAsFiles = true
            showPhotoPicker = true
        case .file: showDocumentPicker = true
        case .poll: showPollComposer = true
        case .stickers: showStickers = true
        case .spoiler: sendAsSpoiler.toggle()
        case .videoNote: showVideoNoteRecorder = true
        case .scheduled:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                client.errorMessage = "Сначала введите текст сообщения"
                return
            }
            showScheduleComposer = true
        }
    }

    private func sendScheduledText(at date: Foundation.Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let reply = takeReply()
        client.sendText(
            text, to: chatId, replyTo: reply, spoiler: sendAsSpoiler,
            scheduleDate: date, replyQuote: replyQuote, replyQuotePosition: replyQuotePosition
        )
        text = ""
        drafts.clear(for: chatId)
        sendAsSpoiler = false
    }

    private func loadDraft() {
        guard editing == nil, text.isEmpty else { return }
        text = drafts.draft(for: chatId)
    }

    /// Sends the composer text as a .txt document.
    private func sendTextAsFile() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("txty", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = TextFileHeuristics.suggestedExtension(for: content)
        let fileURL = directory.appendingPathComponent("message-\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            client.sendDocument(fileURL, caption: "", to: chatId, replyTo: takeReply())
            text = ""
        } catch {
            client.errorMessage = "Не удалось создать файл: \(error.localizedDescription)"
        }
    }

    private func sendEncryptedNote(key: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        do {
            let payload = try CryptoNotes.encrypt(content, passphrase: key)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("note-\(Int(Foundation.Date().timeIntervalSince1970)).fgn.enc")
            try payload.write(to: url, atomically: true, encoding: .utf8)
            client.sendDocument(url, caption: "Зашифрованная заметка", to: chatId, replyTo: takeReply())
            text = ""
        } catch {
            client.errorMessage = "Не удалось зашифровать: \(error.localizedDescription)"
        }
    }

    private func decryptNote(_ request: DecryptRequest, key: String) {
        Task {
            guard let client = TelegramClient.shared.tdClient else { return }
            do {
                let file = try await client.downloadFile(fileId: request.fileId,
                                                        limit: 0, offset: 0, priority: 32,
                                                        synchronous: true)
                let payload = try String(contentsOfFile: file.local.path, encoding: .utf8)
                let plain = try CryptoNotes.decrypt(payload, passphrase: key)
                decryptedNote = DecryptedNote(id: request.id, text: plain)
            } catch {
                TelegramClient.shared.errorMessage = "Не удалось расшифровать: неверный ключ или повреждённый файл"
            }
        }
    }

    private func sendRoundVideo(_ url: URL) {
        preparingMedia += 1
        Task {
            do {
                let result = try await RoundVideoConverter.convert(url)
                client.sendVideoNote(result.url, duration: result.duration, length: 640,
                                     to: chatId, replyTo: takeReply())
            } catch {
                client.errorMessage = "Не удалось подготовить кружок: \(error.localizedDescription)"
            }
            preparingMedia -= 1
        }
    }

    private func sendText() {
        if editing == nil,
           autoTextFileThreshold > 0,
           text.trimmingCharacters(in: .whitespacesAndNewlines).count > autoTextFileThreshold {
            sendTextAsFile()
            return
        }
        if let editing {
            client.editMessage(editing, text: text)
            self.editing = nil
        } else {
            client.sendText(
                text,
                to: chatId,
                replyTo: takeReply(),
                spoiler: sendAsSpoiler,
                replyQuote: replyQuote,
                replyQuotePosition: replyQuotePosition
            )
            sendAsSpoiler = false
            replyQuote = nil
            replyQuotePosition = 0
        }
        text = ""
    }

    private func takeReply() -> Int64? {
        defer { replyTo = nil }
        return replyTo?.id
    }

    private func startReply(_ message: TDLibKit.Message) {
        editing = nil
        replyTo = message
    }

    private func startVoice() {
        Task {
            if await voice.start() {
                client.sendChatAction(.chatActionRecordingVoiceNote, chatId: chatId)
            }
        }
    }

    private func handle(_ action: MessageAction, for message: TDLibKit.Message) {
        switch action {
        case .reply:
            startReply(message)
        case .copy:
            UIPasteboard.general.string = MessageFormatter.caption(of: message.content)?.text
        case .edit:
            replyTo = nil
            editing = message
            text = MessageFormatter.caption(of: message.content)?.text ?? ""
        case .forward:
            // Let the actions sheet finish dismissing before presenting the next one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { forwardMessage = message }
        case .react(let type):
            client.toggleReaction(type, on: message)
        case .addToMusic(let audio):
            Task { await MusicLibrary.shared.importTelegram(audio: audio) }
        case .pin(let isPinned):
            if isPinned {
                client.pinMessage(message)
            } else {
                client.unpinMessage(message)
            }
        case .saveMedia:
            Task { await saveMedia(message) }
        case .saveSticker:
            Task { await saveSticker(message, wholePack: false) }
        case .saveStickerPack:
            Task { await saveSticker(message, wholePack: true) }
        case .replies:
            repliesMessage = message
        case .favoriteAnimation:
            if case .messageAnimation(let animation) = message.content {
                Task {
                    do {
                        try await client.addAnimationToFavoriteSticker(animation.animation)
                        saveAlertText = "Гифка добавлена в избранные стикеры"
                        showSaveAlert = true
                    } catch {
                        client.errorMessage = TelegramClient.describe(error)
                    }
                }
            }
        case .sendAnimationSticker:
            if case .messageAnimation(let animation) = message.content {
                client.sendAnimationAsSticker(animation.animation, to: chatId)
            }
        case .setMemberTag(let userId):
            tagUserId = userId
        case .stickerSet(let setId):
            previewStickerSetId = setId
        case .saveToSaved:
            if let me = client.me {
                client.forward(message, to: me.id)
            }
        case .quote:
            quoteMessage = message
        case .translate(let text):
            translationTarget = TranslationTarget(text: text)
        case .translateOnDevice(let text):
            appleTranslateText = AppleTranslationTarget(text: text)
        case .decryptNote:
            if case .messageDocument(let document) = message.content {
                decryptRequest = DecryptRequest(id: message.id,
                                                fileId: document.document.document.id,
                                                fileName: document.document.fileName)
            }
        case .saveGif:
            if case .messageAnimation(let animation) = message.content {
                Task {
                    do {
                        try await client.saveAnimationToTelegram(animation.animation)
                    } catch {
                        client.errorMessage = TelegramClient.describe(error)
                    }
                    _ = await GifLibrary.shared.save(animation.animation)
                    saveAlertText = "Гифка сохранена в раздел «Гифки»"
                    showSaveAlert = true
                }
            }
        case .call(let phoneNumber):
            client.call(phoneNumber: phoneNumber)
        case .block(let userId, let isBlocked):
            client.setUserBlocked(userId: userId, isBlocked: isBlocked)
        case .delete(let forAll):
            client.deleteMessages(chatId: chatId, ids: [message.id], forAll: forAll)
        }
    }

    /// Opens a private chat with the message sender (or the sender channel).
    private func openSender(_ sender: MessageSender) {
        switch sender {
        case .messageSenderUser(let user):
            if chat?.privateUserId == user.userId { return }
            Task {
                do {
                    let id = try await client.openChat(userId: user.userId)
                    if id != chatId { taggedChatId = id }
                } catch {
                    client.errorMessage = TelegramClient.describe(error)
                }
            }
        case .messageSenderChat(let senderChat):
            if senderChat.chatId != chatId {
                taggedChatId = senderChat.chatId
            }
        }
    }

    /// Opens @mentions and t.me links inside the app instead of Safari.
    private func handleInternalLink(_ url: URL) -> Bool {
        guard let username = Self.username(from: url) else { return false }
        Task {
            if let id = await client.resolveUsername(username) {
                if id != chatId {
                    taggedChatId = id
                }
            } else {
                client.errorMessage = "Не удалось открыть @\(username)"
            }
        }
        return true
    }

    private static func username(from url: URL) -> String? {
        let host = url.host?.lowercased()
        if host == "t.me" || host == "telegram.me" || host == "www.t.me" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard let first = parts.first, !first.isEmpty,
                  !first.hasPrefix("+"), first != "joinchat", first != "s" else { return nil }
            return first
        }
        if url.scheme == "tg", url.host == "resolve" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "domain" })?
                .value
        }
        return nil
    }

    private static func pinnedPreview(_ message: TDLibKit.Message) -> String {
        let preview = MessageFormatter.preview(message.content)
        return preview.isEmpty ? "Сообщение" : preview
    }

    private func pinnedBanner(_ message: TDLibKit.Message) -> some View {
        HStack(spacing: 10) {
            Button {
                jump(to: message.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pin.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Закреплённое сообщение")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                        Text(Self.pinnedPreview(message))
                            .font(.appFootnote)
                            .lineLimit(1)
                            .foregroundColor(.primary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                showPinned = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Все закреплённые")
            Button {
                client.unpinMessage(message)
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Открепить")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .task(id: message.id) {
            if MessageFormatter.preview(message.content).isEmpty {
                client.refreshPinnedMessage(chatId: chatId, messageId: message.id)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func saveSticker(_ message: TDLibKit.Message, wholePack: Bool) async {
        guard case .messageSticker(let content) = message.content else { return }
        stickerSaveBusy = true
        defer { stickerSaveBusy = false }
        do {
            if wholePack {
                try await client.installStickerSet(content.sticker)
                saveAlertText = "Стикерпак добавлен в наборы стикеров"
            } else {
                try await client.addFavoriteSticker(content.sticker)
                saveAlertText = "Стикер добавлен в избранные"
            }
            showSaveAlert = true
        } catch {
            client.errorMessage = TelegramClient.describe(error)
        }
    }

    private func saveMedia(_ message: TDLibKit.Message) async {
        guard let file = message.content.saveableFile else {
            client.errorMessage = "Это сообщение нельзя сохранить"
            return
        }
        guard let url = await client.localFileURL(file) else {
            client.errorMessage = "Не удалось скачать файл"
            return
        }

        if message.content.isPhotoMedia || message.content.isVideoMedia {
            if let error = await MediaSaver.saveToPhotos(url, isVideo: message.content.isVideoMedia) {
                client.errorMessage = error
            } else {
                saveAlertText = message.content.isVideoMedia
                    ? "Видео сохранено в «Фото»"
                    : "Фото сохранено в «Фото»"
                showSaveAlert = true
            }
        } else {
            // Files, audio and other documents: system share sheet includes
            // "Save to Files" and other destinations.
            shareItem = ShareItem(url: url)
        }
    }

    /// Prepares picked photos/videos, then shows the caption composer instead of sending.
    private func preparePicked(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        showPhotoPicker = false
        preparingMedia += providers.count
        Task {
            var items: [OutgoingMedia] = []
            for provider in providers {
                defer { preparingMedia = max(0, preparingMedia - 1) }
                if sendMediaAsFiles {
                    let type: UTType = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? .movie : .image
                    if let original = await MediaPreparer.originalFile(provider, type: type) {
                        items.append(OutgoingMedia(kind: .document(original)))
                    } else {
                        client.errorMessage = "Не удалось подготовить файл без сжатия"
                    }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier("public.movie") || provider.hasItemConformingToTypeIdentifier("public.video") {
                    if let source = await MediaPreparer.loadMovie(provider),
                       let video = await MediaPreparer.video(source) {
                        items.append(OutgoingMedia(kind: .video(video)))
                    } else {
                        client.errorMessage = "Не удалось подготовить видео"
                    }
                } else if let image = await MediaPreparer.loadImage(provider),
                          let photo = MediaPreparer.photo(image) {
                    items.append(OutgoingMedia(kind: .photo(photo, image)))
                } else if let original = await MediaPreparer.loadFile(provider, type: UTType.image.identifier) {
                    // Some providers don't expose a UIImage but can still hand
                    // over the original file. Attach it instead of losing it.
                    items.append(OutgoingMedia(kind: .document(original)))
                } else if let original = await MediaPreparer.loadFile(provider, type: UTType.data.identifier) {
                    items.append(OutgoingMedia(kind: .document(original)))
                } else {
                    client.errorMessage = "Не удалось открыть вложение. Попробуйте ещё раз или выберите файл."
                }
            }
            if items.isEmpty {
                client.errorMessage = "Не удалось прикрепить выбранные файлы"
            }
            presentComposer(items)
            sendMediaAsFiles = false
        }
    }

    /// Documents are copied out of the picker first, then shown with a caption field.
    private func prepareDocuments(_ urls: [URL]) {
        showDocumentPicker = false
        var items: [OutgoingMedia] = []
        for url in urls {
            if let copy = MediaPreparer.document(url) {
                items.append(OutgoingMedia(kind: .document(copy)))
            } else {
                client.errorMessage = "Не удалось подготовить файл \(url.lastPathComponent)"
            }
        }
        presentComposer(items)
    }

    private func presentComposer(_ items: [OutgoingMedia]) {
        guard !items.isEmpty else { return }
        let payload = MediaComposerPayload(items: items, caption: text)
        // Let the system picker finish dismissing before presenting the composer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            composerPayload = payload
        }
    }

    private func sendPreparedMedia(caption: String, media: [OutgoingMedia]) {
        guard !media.isEmpty else { return }

        let reply = takeReply()
        text = ""
        var remainingCaption = caption
        for item in media {
            let itemCaption = remainingCaption
            remainingCaption = ""
            switch item.kind {
            case .photo(let prepared, _):
                client.sendPhoto(
                    prepared.url, width: prepared.width, height: prepared.height,
                    caption: itemCaption, to: chatId, replyTo: reply
                )
            case .video(let prepared):
                client.sendVideo(
                    prepared.url, width: prepared.width, height: prepared.height,
                    duration: prepared.duration, caption: itemCaption, to: chatId, replyTo: reply
                )
            case .document(let url):
                client.sendDocument(url, caption: itemCaption, to: chatId, replyTo: reply)
            }
        }
    }

    // MARK: - Helpers

    private var subtitle: String {
        guard let chat else { return "" }
        if let action = store.actionText(chatId: chatId) { return action }
        if let userId = chat.privateUserId, let user = store.users[userId] {
            if case .userTypeBot = user.type { return "бот" }
            return MessageFormatter.userStatus(store.userStatuses[userId] ?? user.status)
        }
        if chat.isChannel { return "канал" }
        if chat.isGroup { return "группа" }
        return ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    /// Reveals a message found by search, loading its context first if it isn't in memory.
    private func jump(to messageId: Int64) {
        if messages.contains(where: { $0.id == messageId }) {
            expandWindow(to: messageId)
            scrollTarget = nil
            DispatchQueue.main.async { scrollTarget = messageId }
            return
        }
        Task {
            await client.loadContext(chatId: chatId, messageId: messageId)
            expandWindow(to: messageId)
            scrollTarget = nil
            DispatchQueue.main.async { scrollTarget = messageId }
        }
    }

    /// Grows the rendered window so `messageId` is included.
    private func expandWindow(to messageId: Int64) {
        guard let index = unblockedMessages.firstIndex(where: { $0.id == messageId }) else { return }
        let needed = unblockedMessages.count - index
        let base = max(1, limits.effectiveMessagesPerChat)
        if needed > base + extraMessages {
            extraMessages = needed - base
        }
    }

    private func focusOnSearchResultIfNeeded() {
        guard let focusMessageId, !didFocusInitialMessage else { return }
        didFocusInitialMessage = true
        jump(to: focusMessageId)
    }
}

/// Wraps a message for `.sheet(item:)`.
struct Identified: Identifiable {
    let message: TDLibKit.Message
    var id: Int64 { message.id }
}

/// In-chat message search; works for private chats, groups and channels.
struct ChatSearchView: View {
    let chatId: Int64
    let title: String
    let onSelect: (Int64) -> Void

    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [TDLibKit.Message] = []
    @State private var isSearching = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            List {
                ForEach(results) { message in
                    Button {
                        onSelect(message.id)
                        dismiss()
                    } label: {
                        row(for: message)
                    }
                    .buttonStyle(.plain)
                }

                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }

                if let errorText {
                    Text(errorText)
                        .font(.appFootnote)
                        .foregroundColor(.red)
                }

                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   results.isEmpty, !isSearching, errorText == nil {
                    Text("Ничего не найдено")
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Поиск сообщений")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .overlay {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("Введите слово или фразу")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onChange(of: query) { _ in scheduleSearch() }
            .onDisappear { searchTask?.cancel() }
        }
        .navigationViewStyle(.stack)
    }

    private func row(for message: TDLibKit.Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(store.senderName(message.senderId))
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                Text(MessageFormatter.listDate(message.date))
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            Text(MessageFormatter.preview(message.content))
                .font(.appSubheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            isSearching = false
            errorText = nil
            return
        }
        isSearching = true
        errorText = nil
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await client.searchMessages(text, chatId: chatId)
                guard !Task.isCancelled else { return }
                results = found.filter { !store.isSenderBlocked($0.senderId) }
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorText = TelegramClient.describe(error)
                isSearching = false
            }
        }
    }
}

/// Per-chat notification overrides: mute, sound, previews, mentions.
struct ChatNotificationSettingsView: View {
    let chatId: Int64

    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var scopeSettings: ScopeNotificationSettings?
    @State private var errorText: String?
    @State private var isSaving = false

    private var chat: ChatItem? { store.chats[chatId] }
    private var settings: ChatNotificationSettings? { chat?.notificationSettings }

    private var scope: NotificationSettingsScope {
        if chat?.isChannel == true { return .notificationSettingsScopeChannelChats }
        if chat?.isGroup == true { return .notificationSettingsScopeGroupChats }
        return .notificationSettingsScopePrivateChats
    }

    private var effectiveMuteFor: Int {
        guard let settings else { return 0 }
        return settings.useDefaultMuteFor ? (scopeSettings?.muteFor ?? 0) : settings.muteFor
    }

    private var effectiveSoundOn: Bool {
        guard let settings else { return true }
        let id = settings.useDefaultSound ? (scopeSettings?.soundId ?? TdInt64(-1)) : settings.soundId
        return id.rawValue != 0
    }

    private var effectivePreview: Bool {
        guard let settings else { return true }
        return settings.useDefaultShowPreview ? (scopeSettings?.showPreview ?? true) : settings.showPreview
    }

    private var effectiveMentions: Bool {
        guard let settings else { return true }
        let disabled = settings.useDefaultDisableMentionNotifications
            ? (scopeSettings?.disableMentionNotifications ?? false)
            : settings.disableMentionNotifications
        return !disabled
    }

    var body: some View {
        NavigationView {
            Form {
                if let settings {
                    Section {
                        Toggle("Уведомления", isOn: Binding(
                            get: { effectiveMuteFor == 0 },
                            set: { enabled in
                                update {
                                    $0.replacing(
                                        muteFor: enabled ? 0 : MuteOption.forever.rawValue,
                                        useDefaultMuteFor: false
                                    )
                                }
                            }
                        ))
                        if effectiveMuteFor > 0 {
                            Picker("Не беспокоить", selection: Binding(
                                get: { MuteOption(rawValue: effectiveMuteFor) ?? .forever },
                                set: { option in
                                    update { $0.replacing(muteFor: option.rawValue, useDefaultMuteFor: false) }
                                }
                            )) {
                                ForEach(MuteOption.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                        }
                        Toggle("Звук", isOn: Binding(
                            get: { effectiveSoundOn },
                            set: { enabled in
                                update {
                                    $0.replacing(
                                        soundId: enabled ? TdInt64(-1) : TdInt64(0),
                                        useDefaultSound: false
                                    )
                                }
                            }
                        ))
                        Toggle("Показывать текст сообщения", isOn: Binding(
                            get: { effectivePreview },
                            set: { enabled in
                                update { $0.replacing(showPreview: enabled, useDefaultShowPreview: false) }
                            }
                        ))
                    } header: {
                        Text(chat?.title ?? "Чат")
                    } footer: {
                        Text("Индивидуальные настройки этого чата имеют приоритет над настройками для всего типа чатов.")
                            .font(.appFootnote)
                    }

                    Section {
                        Toggle("Уведомления об упоминаниях", isOn: Binding(
                            get: { effectiveMentions },
                            set: { enabled in
                                update {
                                    $0.replacing(
                                        disableMentionNotifications: !enabled,
                                        useDefaultDisableMentionNotifications: false
                                    )
                                }
                            }
                        ))
                        Button("Сбросить настройки чата") {
                            update { _ in settings.resettingToDefaults() }
                        }
                    } footer: {
                        Text("Сброс возвращает наследование настроек категории.")
                            .font(.appFootnote)
                    }

                    if let errorText {
                        Section {
                            Text(errorText).font(.appFootnote).foregroundColor(.red)
                        }
                    }
                } else {
                    Text("Чат не найден").foregroundColor(.secondary)
                }
            }
            .navigationTitle("Уведомления")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSaving {
                    ProgressView().padding(8)
                }
            }
            .task {
                scopeSettings = try? await client.notificationSettings(scope: scope)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func update(_ transform: (ChatNotificationSettings) -> ChatNotificationSettings) {
        guard let current = chat?.notificationSettings else { return }
        let updated = transform(current)
        store.updateChat(chatId) { $0.notificationSettings = updated }
        isSaving = true
        Task {
            do {
                try await client.setChatNotificationSettings(chatId: chatId, settings: updated)
                errorText = nil
            } catch {
                errorText = TelegramClient.describe(error)
            }
            isSaving = false
        }
    }
}


/// The chat should use the whole screen; the music tab returns after going back.
private struct HidesTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbar(.hidden, for: .tabBar)
        } else {
            content
        }
    }
}


/// Observes the underlying UIScrollView so "is at bottom" works reliably on iOS 15
/// (SwiftUI has no scroll-position API there).
struct ScrollBottomObserver: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator {
        private let onChange: (Bool) -> Void
        private weak var scrollView: UIScrollView?
        private var observations: [NSKeyValueObservation] = []
        private var lastValue: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        func attach(from view: UIView, attempt: Int = 0) {
            var ancestor = view.superview
            while let current = ancestor {
                if let scroll = current as? UIScrollView {
                    attach(scroll)
                    return
                }
                ancestor = current.superview
            }
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                guard let self, let view else { return }
                self.attach(from: view, attempt: attempt + 1)
            }
        }

        private func attach(_ scroll: UIScrollView) {
            guard scroll !== scrollView else { return }
            detach()
            scrollView = scroll

            let schedule: () -> Void = { [weak self] in
                DispatchQueue.main.async { self?.update() }
            }
            observations = [
                scroll.observe(\.contentOffset, options: [.new, .initial]) { _, _ in schedule() },
                scroll.observe(\.contentSize, options: [.new, .initial]) { _, _ in schedule() },
                scroll.observe(\.bounds, options: [.new, .initial]) { _, _ in schedule() },
                scroll.observe(\.adjustedContentInset, options: [.new, .initial]) { _, _ in schedule() }
            ]
            update()
        }

        private func update() {
            guard let scroll = scrollView else { return }
            let bottomInset = scroll.adjustedContentInset.bottom
            let visibleBottom = scroll.contentOffset.y + scroll.bounds.height - bottomInset
            let atBottom = visibleBottom >= scroll.contentSize.height - 24
            guard atBottom != lastValue else { return }
            lastValue = atBottom
            Task { @MainActor in
                self.onChange(atBottom)
            }
        }

        func detach() {
            observations.forEach { $0.invalidate() }
            observations = []
            scrollView = nil
            lastValue = nil
        }
    }
}


private struct IdentifiedInt: Identifiable {
    let value: Int64
    var id: Int64 { value }
}


private struct IdentifiedTdInt: Identifiable {
    let value: TdInt64
    var id: TdInt64 { value }
}


private struct MediaComposerPayload: Identifiable {
    let id = UUID()
    let items: [OutgoingMedia]
    let caption: String
}


private struct TranslationTarget: Identifiable {
    let id = UUID()
    let text: String
}


struct HideTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbar(.hidden, for: .tabBar)
        } else {
            content
        }
    }
}






private struct AppleTranslationTarget: Identifiable {
    let id = UUID()
    let text: String
}


private struct DecryptRequest: Identifiable {
    let id: Int64
    let fileId: Int
    let fileName: String
}

private struct DecryptedNote: Identifiable {
    let id: Int64
    let text: String
}

