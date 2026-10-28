import SwiftUI
import Combine
import UIKit
import TDLibKit

/// Main chat list. Uses a plain stable row (no presentation cache) — that cache
/// caused a main-thread freeze, so rows read directly from ChatStore.
struct ChatListView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var aliases = LocalAliases.shared
    @ObservedObject private var visitHistory = ChatVisitHistory.shared
    @ObservedObject private var ultra = UltraMode.shared
    @ObservedObject private var classic = ClassicDesignMode.shared
    @ObservedObject private var globalSearch = GlobalSearchPreferences.shared
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var limits = DisplayLimits.shared
    @ObservedObject private var searchHistory = SearchHistory.shared
    @ObservedObject private var proxy = BuiltInProxyManager.shared
    @ObservedObject private var recentContacts = RecentContactsStore.shared
    @ObservedObject private var hiddenChats = HiddenChats.shared
    @ObservedObject private var autoTranslation = AutoTranslationManager.shared
    @AppStorage("recentContactsEnabled") private var recentContactsEnabled = true
    @ObservedObject private var deepLinks = DeepLinkRouter.shared

    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var confirmLogout = false
    @State private var showSettings = false
    @State private var showProxy = false
    @State private var showNewsFeed = false
    @State private var showClassicMusic = false
    @State private var showVisitHistory = false
    @State private var showSearchHistory = false
    @State private var showProfile = false
    @State private var showNewChat = false
    @State private var createKind: CreateChatKind?
    @State private var showAccounts = false
    @State private var showClassicProfileMenu = false
    @State private var openTarget: ChatTarget?
    @State private var searchResults: [TDLibKit.Message] = []
    @State private var contactResults: [TDLibKit.User] = []
    @State private var channelResults: [Int64] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var extraChats = 0

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static let settingsSearchItems: [(String, [String])] = [
        ("Прокси", ["прокси", "proxy", "сеть"]),
        ("Настройки", ["настройки", "settings"]),
        ("Уведомления", ["уведомления", "notification"]),
        ("Память и кэш", ["кэш", "память", "очистка", "cache"]),
        ("Оптимизация", ["оптимизация", "батарея", "энергия"]),
        ("Приватность", ["приватность", "невидимка"]),
        ("Лимиты отображения", ["лимиты", "limits"]),
        ("Для разработчиков", ["разработчик", "debug", "терминал"])
    ]

    private var matchedSettings: [String] {
        guard !query.isEmpty else { return [] }
        let normalized = SearchMatcher.normalized(query)
        return Self.settingsSearchItems.compactMap { item in
            item.1.contains { SearchMatcher.matches($0, query: normalized) } ? item.0 : nil
        }
    }

    private var savedChatId: Int64? {
        store.chats.first { $0.value.privateUserId == client.me?.id }?.key
    }

    private var orderedChatIds: [Int64] {
        let mainSet = Set(store.mainChatIds)
        let local = store.localPinnedChatIds.filter { mainSet.contains($0) }
        let localSet = Set(local)
        var result: [Int64] = []
        if let last = store.lastOpenedChatId, mainSet.contains(last) { result.append(last) }
        result += local.filter { $0 != store.lastOpenedChatId }
        result += store.mainChatIds.filter { !localSet.contains($0) && $0 != store.lastOpenedChatId }
        if let savedChatId, store.chats[savedChatId] != nil {
            result.removeAll { $0 == savedChatId }
            result.insert(savedChatId, at: 0)
        }
        return result
    }

    private var normalizedQuery: String { SearchMatcher.normalized(query) }

    /// Users matched by their local tag/alias or username, even when server
    /// search does not know about the tag.
    private func aliasMatchedUserIds(_ text: String) -> [Int64] {
        let normalized = SearchMatcher.normalized(text)
        guard !normalized.isEmpty else { return [] }
        return store.users.values.compactMap { user in
            if let alias = aliases.userAlias(user.id), SearchMatcher.matches(alias, query: normalized) {
                return user.id
            }
            let usernames = user.usernames?.activeUsernames ?? []
            if usernames.contains(where: { SearchMatcher.matches($0, query: normalized) }) {
                return user.id
            }
            return nil
        }
    }

    private var chatIds: [Int64] {
        let base = orderedChatIds
        guard !query.isEmpty else { return base }
        let normalized = normalizedQuery
        return base.filter { id in
            guard let chat = store.chats[id] else { return false }
            if SearchMatcher.matches(displayTitle(chat), query: normalized) { return true }
            if let userId = chat.privateUserId,
               let alias = aliases.userAlias(userId),
               SearchMatcher.matches(alias, query: normalized) { return true }
            if let userId = chat.privateUserId,
               let user = store.users[userId],
               let usernames = user.usernames?.activeUsernames,
               usernames.contains(where: { SearchMatcher.matches($0, query: normalized) }) { return true }
            return false
        }
    }

    private var displayedChatIds: [Int64] {
        var limit = max(1, limits.effectiveRenderedChats + extraChats)
        if DevicePerformance.isLowMemory { limit = min(limit, 40) }
        return Array(chatIds.filter { hiddenChats.isVisible($0) }.prefix(limit))
    }

    private func displayTitle(_ chat: ChatItem) -> String {
        let base = aliases.chatAlias(chat.id) ?? chat.title
        if let cached = autoTranslation.translation(forChatId: chat.id, title: base) {
            return cached
        }
        autoTranslation.requestChatTitle(chatId: chat.id, title: base)
        return base
    }

    private func isPinned(_ chat: ChatItem) -> Bool {
        chat.id == savedChatId || chat.isPinned || store.isLocallyPinned(chat.id)
    }

    private func togglePin(_ chat: ChatItem) {
        if chat.id == savedChatId { return }
        client.setPinned(chatId: chat.id, isPinned: !isPinned(chat))
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if classic.isEnabled { classicHeader }
                List {
                    if player.current != nil { GlobalPlayerBar() }
                    if query.isEmpty && classic.isEnabled && searchFocused && !searchHistory.items.isEmpty {
                        Section("Недавние запросы") {
                            ForEach(searchHistory.items, id: \.self) { item in
                                Button {
                                    search = item
                                    searchFocused = true
                                } label: {
                                    Label(item, systemImage: "clock.arrow.circlepath")
                                }
                            }
                        }
                    }
                    if !query.isEmpty && !matchedSettings.isEmpty {
                        Section("Настройки") {
                            ForEach(matchedSettings, id: \.self) { name in
                                Button {
                                    switch name {
                                    case "Прокси": showProxy = true
                                    default: showSettings = true
                                    }
                                } label: {
                                    Label(name, systemImage: "gearshape")
                                }
                            }
                        }
                    }
                    if !query.isEmpty && (globalSearch.isEnabled || !contactResults.isEmpty) {
                        searchSection
                    }
                    if store.chats.isEmpty && client.isLoadingChats {
                        ForEach(0..<8, id: \.self) { _ in
                            ChatRowSkeleton()
                                .listRowSeparator(.hidden)
                        }
                    }
                    ForEach(displayedChatIds, id: \.self) { chatId in
                        if let chat = store.chats[chatId] {
                            chatRow(chat)
                        }
                    }
                    if client.isLoadingChats {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                    if chatIds.count > displayedChatIds.count {
                        Text("Показать ещё \(min(max(10, limits.effectiveRenderedChats), chatIds.count - displayedChatIds.count))")
                            .font(.appFootnote)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                extraChats += max(10, limits.effectiveRenderedChats)
                            }
                            .glassPanel(cornerRadius: 14)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .transaction { transaction in
                    // Keep scrolling jank-free, but animate the initial load.
                    if transaction.animation == nil && store.chats.isEmpty {
                        transaction.animation = .easeInOut(duration: 0.25)
                    }
                }
            }
            .searchable(text: $search, prompt: "Поиск чатов, каналов, контактов")
            .navigationBarHidden(classic.isEnabled)
            .navigationTitle("Fignyagram")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !classic.isEnabled {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showSearchHistory = true } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 16) {
                            Button { showNewsFeed = true } label: {
                                Image(systemName: "newspaper")
                            }
                            composeMenu
                            profileMenu
                        }
                    }
                }
            }

            .onChange(of: search) { _ in scheduleSearch() }
            .sheet(isPresented: $showClassicMusic) {
                NavigationView {
                    MusicView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Закрыть") { showClassicMusic = false }
                            }
                        }
                }
                .navigationViewStyle(.stack)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNewsFeed) { NewsFeedView() }
            .sheet(isPresented: $showProfile) { ProfileSettingsView() }
            .sheet(isPresented: $showAccounts) { AccountsView() }
            .sheet(item: $createKind) { kind in
                CreateChatView(kind: kind) { chatId in
                    openTarget = ChatTarget(chatId: chatId, messageId: nil)
                }
            }
            .sheet(isPresented: $showNewChat) {
                ChatPickerView(title: "Новое сообщение") { chatId in
                    openTarget = ChatTarget(chatId: chatId, messageId: nil)
                }
            }
            .sheet(isPresented: $showProxy) { ProxySettingsView() }
            .sheet(isPresented: $showVisitHistory) { visitHistoryView }
            .sheet(isPresented: $showSearchHistory) {
                SearchHistoryView(onPick: { item in
                    search = item
                    searchFocused = true
                }, onOpenContact: { userId in
                    Task {
                        if let chatId = try? await client.openChat(userId: userId) {
                            openTarget = ChatTarget(chatId: chatId, messageId: nil)
                        }
                    }
                })
            }
            .sheet(isPresented: $showClassicProfileMenu) {
                ClassicProfileMenuView(onSettings: { showSettings = true }, onLogout: { confirmLogout = true })
            }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { client.logOut() }
            }
            .safeAreaInset(edge: .bottom) {
                ErrorBanner(message: client.errorMessage)
                    .onTapGesture { client.errorMessage = nil }
            }
            .background(openChatLink)
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .onDisappear { dismissKeyboard() }
            .onChange(of: openTarget) { target in
                if target == nil { ChatPresentationState.shared.reset() }
            }
            .onAppear { ChatPresentationState.shared.reset() }
            .onChange(of: deepLinks.pendingUsername) { username in
                guard let username, !username.isEmpty else { return }
                deepLinks.pendingUsername = nil
                Task {
                    if let chatId = try? await client.openChat(username: username) {
                        openTarget = ChatTarget(chatId: chatId, messageId: nil)
                    }
                }
            }
            .onChange(of: chatIds) { ids in
                if let last = ids.last, last == store.mainChatIds.last { client.loadMoreChats() }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Rows

    @ViewBuilder
    /// Precomputed once per body pass instead of scanning visit history per row.
    private var recentVisitChatIds: Set<Int64> {
        var ids = Set<Int64>()
        for visit in visitHistory.visits.prefix(3) { ids.insert(visit.chatId) }
        return ids
    }

    private func chatRow(_ chat: ChatItem) -> some View {
        Button {
            openTarget = ChatTarget(chatId: chat.id, messageId: nil)
        } label: {
            ChatRow(
                chat: displayedChat(chat),
                actionText: store.actionText(chatId: chat.id),
                senderName: chat.isGroup ? store.senderName(chat.lastMessage?.senderId ?? .messageSenderUser(MessageSenderUser(userId: 0))) : "",
                isPinned: isPinned(chat),
                hidesLastMessage: chat.lastMessage.map { store.isSenderBlocked($0.senderId) } ?? false,
                isRecent: !ultra.isEnabled && recentVisitChatIds.contains(chat.id),
                isSaved: chat.id == savedChatId,
                isLastOpened: chat.id == store.lastOpenedChatId,
                presence: presence(for: chat),
                fallbackPreview: historyPreview(chatId: chat.id)
            )
            .equatable()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if chat.id != savedChatId {
                Button { togglePin(chat) } label: {
                    Label(isPinned(chat) ? "Открепить" : "Закрепить", systemImage: "pin.fill")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            if chat.id == store.lastOpenedChatId {
                Button { showVisitHistory = true } label: {
                    Label("История заходов", systemImage: "clock.arrow.circlepath")
                }
            }
            Button { togglePin(chat) } label: {
                Label(isPinned(chat) ? "Открепить от верха" : "Закрепить сверху", systemImage: "pin")
            }
            if chat.privateUserId != nil || chat.isGroup || chat.isChannel {
                Button { client.copyUsername(for: chat) } label: {
                    Label("Скопировать юзернейм", systemImage: "at")
                }
            }
            if chat.isGroup && !chat.isChannel {
                Button {
                    Task { await GroupCallManager.shared.startOrJoin(chatId: chat.id, title: chat.title, video: false) }
                } label: {
                    Label("Голосовой чат", systemImage: "waveform")
                }
                Button {
                    Task { await GroupCallManager.shared.startOrJoin(chatId: chat.id, title: chat.title, video: true) }
                } label: {
                    Label("Видеочат", systemImage: "video.badge.waveform")
                }
            }
            if let userId = chat.privateUserId, userId != client.me?.id {
                Button { client.callUser(userId: userId, isVideo: false) } label: {
                    Label("Позвонить", systemImage: "phone")
                }
                Button { client.callUser(userId: userId, isVideo: true) } label: {
                    Label("Видеозвонок", systemImage: "video")
                }
            }
            if let userId = chat.privateUserId {
                Button {
                    client.setUserBlocked(userId: userId, isBlocked: !store.isUserBlocked(userId))
                } label: {
                    Label(store.isUserBlocked(userId) ? "Разблокировать" : "Заблокировать", systemImage: "hand.raised")
                }
            }
        }
    }

    private func displayedChat(_ chat: ChatItem) -> ChatItem {
        guard let alias = aliases.chatAlias(chat.id) else { return chat }
        var copy = chat
        copy.title = alias
        return copy
    }

    // MARK: - Search

    @ViewBuilder
    private var searchSection: some View {
        if !contactResults.isEmpty {
            Section("Контакты") {
                ForEach(contactResults) { user in
                    Button {
                        Task { await openContact(user) }
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(id: user.id, title: [user.firstName, user.lastName].joined(separator: " "), photo: nil, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text([user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "))
                                if !user.phoneNumber.isEmpty {
                                    Text("+\(user.phoneNumber)").font(.appCaption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.appCaption).foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !channelResults.isEmpty {
            Section("Каналы") {
                ForEach(channelResults, id: \.self) { chatId in
                    if let chat = store.chats[chatId] {
                        Button { openTarget = ChatTarget(chatId: chatId, messageId: nil) } label: {
                            HStack(spacing: 10) {
                                AvatarView(id: chat.id, title: chat.title, photo: chat.photo, size: 36)
                                Text(chat.title).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        if !searchResults.isEmpty {
            Section("Сообщения") {
                ForEach(searchResults, id: \.id) { message in
                    Button {
                        openTarget = ChatTarget(chatId: message.chatId, messageId: message.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.chats[message.chatId]?.title ?? "Чат")
                                .font(.appCaption.bold())
                                .foregroundColor(.accentColor)
                            Text(MessageFormatter.preview(message.content)).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func openContact(_ user: TDLibKit.User) async {
        do {
            let chatId = try await client.openChat(userId: user.id)
            openTarget = ChatTarget(chatId: chatId, messageId: nil)
        } catch {
            // Fallback: some accounts can only be opened through a public username.
            if let username = user.usernames?.activeUsernames.first,
               let chatId = try? await client.openChat(username: username) {
                openTarget = ChatTarget(chatId: chatId, messageId: nil)
            } else {
                client.errorMessage = TelegramClient.describe(error)
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        guard !text.isEmpty else {
            searchResults = []; contactResults = []; channelResults = []
            return
        }
        let aliasUsers = aliasMatchedUserIds(text)
        guard globalSearch.isEnabled else {
            // Local tags must still be searchable with global search disabled.
            searchResults = []
            channelResults = []
            contactResults = aliasUsers.compactMap { store.users[$0] }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            var contacts = (try? await client.searchContacts(text)) ?? []
            // Phone lookup by first/last 4 digits, even if Telegram's contact
            // search didn't return the person yet.
            let digits = text.filter { $0.isNumber }
            if digits.count >= 3 {
                let local = store.users.values.filter { user in
                    let phone = user.phoneNumber.filter { $0.isNumber }
                    guard !phone.isEmpty else { return false }
                    return phone.hasPrefix(digits) || phone.hasSuffix(digits) || phone.contains(digits)
                }
                for user in local where !contacts.contains(where: { $0.id == user.id }) {
                    contacts.append(user)
                }
            }
            for userId in aliasUsers where !contacts.contains(where: { $0.id == userId }) {
                if let user = store.users[userId] { contacts.append(user) }
            }
            guard search.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            contactResults = contacts
            channelResults = (try? await client.searchChannels(text)) ?? []
            let found = (try? await client.searchMessages(text)) ?? []
            let savedId = client.me?.id
            searchResults = found.filter { $0.chatId != savedId }
            if !contactResults.isEmpty || !channelResults.isEmpty || !searchResults.isEmpty {
                searchHistory.record(text)
            }
        }
    }

    private func historyPreview(chatId: Int64) -> String? {
        guard let message = store.messages[chatId]?.last else { return nil }
        return MessageFormatter.preview(message.content)
    }

    private func presence(for chat: ChatItem) -> String? {
        guard store.actionText(chatId: chat.id) == nil else { return nil }
        guard let userId = chat.privateUserId, let user = store.users[userId] else { return nil }
        if case .userTypeBot = user.type { return nil }
        switch user.status {
        case .userStatusOnline: return "в сети"
        case .userStatusRecently: return "был(а) недавно"
        case .userStatusLastWeek: return "был(а) на этой неделе"
        case .userStatusLastMonth: return "был(а) в этом месяце"
        default: return nil
        }
    }

    private var composeMenu: some View {
        Menu {
            Button { createKind = .channel } label: {
                Label("Новый канал", systemImage: "megaphone")
            }
            Button { createKind = .group } label: {
                Label("Новая группа", systemImage: "person.2")
            }
            Button { showNewChat = true } label: {
                Label("Новое сообщение", systemImage: "bubble.left.and.bubble.right")
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 21))
                .foregroundColor(.accentColor)
        }
    }

    private var recentContactsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(recentContacts.userIds, id: \.self) { userId in
                    if let user = store.users[userId] {
                        Button {
                            Task {
                                if let chatId = try? await client.openChat(userId: userId) {
                                    openTarget = ChatTarget(chatId: chatId, messageId: nil)
                                }
                            }
                        } label: {
                            VStack(spacing: 4) {
                                LegacyAvatarView(
                                    id: userId,
                                    title: [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "),
                                    file: user.profilePhoto?.big,
                                    size: 46
                                )
                                Text(user.firstName)
                                    .font(.appCaption2)
                                    .lineLimit(1)
                                    .frame(width: 54)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var normalHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Поиск чатов, каналов, контактов", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .glassPanel(cornerRadius: 14)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var profileMenu: some View {
        Menu {
            if let me = client.me {
                Text([me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " "))
                if let username = me.usernames?.activeUsernames.first {
                    Text("@\(username)")
                }
                if !me.phoneNumber.isEmpty { Text("+\(me.phoneNumber)") }
                Divider()
            }
            Button { showProfile = true } label: {
                Label("Профиль", systemImage: "person.crop.circle")
            }
            Button {
                proxy.setEnabled(!proxy.isEnabled)
            } label: {
                Label(
                    proxy.isEnabled ? "Выключить прокси" : "Включить прокси",
                    systemImage: proxy.isEnabled ? "network.slash" : "network"
                )
            }
            Button { showAccounts = true } label: {
                Label("Аккаунты", systemImage: "person.2")
            }
            Button { showSettings = true } label: {
                Label("Настройки", systemImage: "gearshape")
            }
            Button(role: .destructive) { confirmLogout = true } label: {
                Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "person.crop.circle").font(.system(size: 21))
                .foregroundColor(.accentColor)
        }
    }

    // MARK: - Classic header (iOS 18 style)

    private var classicHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Button { showSearchHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 21))
                }
                Spacer()
                Button { showNewsFeed = true } label: {
                    Image(systemName: "newspaper")
                        .font(.system(size: 21))
                }
                Button { showClassicMusic = true } label: {
                    Image(systemName: "music.note")
                        .font(.system(size: 21))
                }
                composeMenu
                profileMenu
                    .font(.system(size: 21))
            }
            .foregroundColor(.accentColor)

            Text("Fignyagram")
                .font(.system(size: 34, weight: .bold))

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Поиск чатов, каналов, контактов", text: $search)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .glassPanel(cornerRadius: 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Visit history

    private var visitHistoryView: some View {
        NavigationView {
            List(visitHistory.visits) { visit in
                Button {
                    showVisitHistory = false
                    openTarget = ChatTarget(chatId: visit.chatId, messageId: nil)
                } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.chats[visit.chatId]?.title ?? "Чат \(visit.chatId)")
                        Text(visit.lastVisited, style: .date)
                            .font(.appCaption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(visit.visits)×").font(.appCaption.monospacedDigit()).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("История заходов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { showVisitHistory = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var openChatLink: some View {
        NavigationLink(
            destination: Group {
                if let target = openTarget {
                    ChatView(chatId: target.chatId, focusMessageId: target.messageId)
                }
            },
            isActive: Binding(
                get: { openTarget != nil },
                set: { if !$0 { openTarget = nil } }
            )
        ) { EmptyView() }
        .hidden()
    }
}

/// A chat to open, optionally focused on a specific message (search result).
struct ChatTarget: Identifiable, Equatable {
    let chatId: Int64
    let messageId: Int64?
    var id: String { "\(chatId)-\(messageId ?? 0)" }
}

struct ChatRow: View {
    let chat: ChatItem
    let actionText: String?
    let senderName: String
    let isPinned: Bool
    let hidesLastMessage: Bool
    var isRecent = false
    var isSaved = false
    var isLastOpened = false
    var presence: String?
    var fallbackPreview: String?

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(id: chat.id, title: chat.title, photo: chat.photo)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if chat.isChannel { Image(systemName: "megaphone.fill").font(.appCaption).foregroundColor(.secondary) }
                    else if chat.isGroup { Image(systemName: "person.2.fill").font(.appCaption).foregroundColor(.secondary) }
                    Text(chat.title).font(.appHeadline).lineLimit(1)
                    if isSaved {
                        Text("Избранное").font(.appCaption2.bold()).padding(.horizontal, 5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundColor(.accentColor)
                    } else if isLastOpened {
                        Text("Недавний").font(.appCaption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let message = chat.lastMessage {
                        if message.isOutgoing {
                            Text(message.id <= chat.lastReadOutboxMessageId ? "✓✓" : "✓")
                                .font(.appCaption).foregroundColor(.accentColor)
                        }
                        Text(MessageFormatter.listDate(message.date))
                            .font(.appCaption).foregroundColor(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    if let action = actionText {
                        Text(action).font(.appSubheadline).foregroundColor(.accentColor).lineLimit(1)
                    } else {
                        Text(preview).font(.appSubheadline).foregroundColor(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if chat.unreadCount > 0 || chat.isMarkedAsUnread {
                        Text(chat.unreadCount > 0 ? "\(chat.unreadCount)" : " ")
                            .font(.caption.bold()).foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor))
                    } else if isPinned {
                        Image(systemName: "pin.fill").font(.appCaption).foregroundColor(.secondary)
                    }
                }
                if let presence, actionText == nil {
                    HStack(spacing: 4) {
                        if presence == "в сети" {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                        }
                        Text(presence)
                            .font(.appCaption2)
                            .foregroundColor(presence == "в сети" ? .green : .secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .id(chat.id)
    }

    private var preview: String {
        guard let message = chat.lastMessage else { return fallbackPreview ?? "Нет сообщений" }
        if hidesLastMessage { return "Сообщение скрыто" }
        var text = MessageFormatter.preview(message.content)
        if text.isEmpty { text = MessageFormatter.serviceText(message.content) ?? "Сообщение" }
        if MessageFormatter.serviceText(message.content) != nil { return text }
        if message.isOutgoing && !chat.isChannel { return "Вы: \(text)" }
        if chat.isGroup { return "\(senderName): \(text)" }
        return text
    }
}

extension ChatRow: Equatable {
    static func == (lhs: ChatRow, rhs: ChatRow) -> Bool {
        lhs.chat == rhs.chat && lhs.actionText == rhs.actionText &&
        lhs.senderName == rhs.senderName && lhs.isPinned == rhs.isPinned &&
        lhs.hidesLastMessage == rhs.hidesLastMessage && lhs.isRecent == rhs.isRecent &&
        lhs.isSaved == rhs.isSaved && lhs.isLastOpened == rhs.isLastOpened &&
        lhs.presence == rhs.presence && lhs.fallbackPreview == rhs.fallbackPreview
    }
}

struct ChatPickerView: View {
    let title: String
    let onPick: (Int64) -> Void
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var orderedIds: [Int64] {
        var ids = store.mainChatIds
        if let saved = store.chats.first(where: { $0.value.privateUserId == client.me?.id })?.key {
            ids.removeAll { $0 == saved }
            ids.insert(saved, at: 0)
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ids }
        return ids.filter { store.chats[$0]?.title.localizedCaseInsensitiveContains(query) == true }
    }

    var body: some View {
        NavigationView {
            List(orderedIds, id: \.self) { chatId in
                if let chat = store.chats[chatId] {
                    Button {
                        onPick(chatId); dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(id: chat.id, title: chat.title, photo: chat.photo, size: 40)
                            Text(chat.title).foregroundColor(.primary).lineLimit(1)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Поиск")
            .modifier(GlassListModifier())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}


/// Lightweight placeholder shown while the first page of chats is loading.
private struct ChatRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 8) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 140, height: 12)
                Capsule()
                    .fill(Color.secondary.opacity(0.10))
                    .frame(height: 10)
            }
        }
        .padding(.vertical, 6)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}
