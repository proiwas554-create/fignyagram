import SwiftUI
import TDLibKit

/// Minimal chat list for iOS 15 / 2 GB devices. The full ChatListView body is
/// too complex for SwiftUI 3 and crashes inside _makeList; this screen keeps
/// only core functionality: list, search, open, unread, pin and settings.
struct LegacyChatListView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var aliases = LocalAliases.shared
    @ObservedObject private var limits = DisplayLimits.shared

    @State private var search = ""
    @State private var openTarget: ChatTarget?
    @State private var showSettings = false
    @State private var showProxy = false
    @State private var showAccounts = false
    @State private var showSearchHistory = false
    @State private var showNewChat = false
    @State private var createKind: CreateChatKind?
    @State private var confirmLogout = false
    @State private var searchRows: [LegacySearchRow] = []
    @State private var extraChats = 0
    @State private var showProfile = false
    @State private var showVisitHistory = false

    private var orderedIds: [Int64] {
        let limit = max(20, limits.effectiveRenderedChats) + extraChats
        var ids = Array(store.mainChatIds.prefix(limit))
        if let saved = store.chats.first(where: { $0.value.privateUserId == client.me?.id })?.key {
            ids.removeAll { $0 == saved }
            ids.insert(saved, at: 0)
        }
        if let last = store.lastOpenedChatId, ids.contains(last) {
            ids.removeAll { $0 == last }
            let index = (savedId != nil && ids.first == savedId) ? 1 : 0
            ids.insert(last, at: min(index, ids.count))
        }
        return ids
    }

    private var totalChatCount: Int {
        var count = store.mainChatIds.count
        if savedId != nil && !store.mainChatIds.contains(savedId!) { count += 1 }
        return count
    }

    private var savedId: Int64? {
        store.chats.first { $0.value.privateUserId == client.me?.id }?.key
    }

    private var chatIds: [Int64] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = orderedIds
        guard !query.isEmpty else { return base }
        return base.filter {
            guard let chat = store.chats[$0] else { return false }
            let title = aliases.chatAlias(chat.id) ?? chat.title
            return title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    List(searchRows) { rowView($0) }
                        .listStyle(.plain)
                } else {
                    List(chatIds, id: \.self) { chatId in
                        if let chat = store.chats[chatId] {
                    Button { openTarget = ChatTarget(chatId: chatId, messageId: nil) } label: {
                        row(chat)
                    }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if chat.id != savedId {
                                Button { client.setPinned(chatId: chat.id, isPinned: !isPinned(chat)) } label: {
                                    Label(isPinned(chat) ? "Открепить" : "Закрепить", systemImage: "pin.fill")
                                }
                                .tint(.orange)
                            }
                        }
                        .contextMenu {
                            Button { client.setPinned(chatId: chat.id, isPinned: !isPinned(chat)) } label: {
                                Label(isPinned(chat) ? "Открепить" : "Закрепить сверху", systemImage: "pin")
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
                    }
                    .listStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if totalChatCount > max(20, limits.effectiveRenderedChats) + extraChats {
                            Button {
                                extraChats += max(20, limits.effectiveRenderedChats)
                            } label: {
                                Text("Показать ещё")
                                    .font(.footnote)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity)
                                    .background(Color(.secondarySystemBackground))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Поиск чатов")
            .onChange(of: search) { _ in scheduleSearch() }
            .navigationTitle("Fignyagram")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button { showSearchHistory = true } label: {
                            Label("История поиска", systemImage: "magnifyingglass")
                        }
                        Button { showVisitHistory = true } label: {
                            Label("История заходов", systemImage: "clock.arrow.circlepath")
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
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
                        }
                        Menu {
                            if let me = client.me {
                                Text([me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " "))
                                if let username = me.usernames?.activeUsernames.first {
                                    Text("@\(username)")
                                }
                                if !me.phoneNumber.isEmpty {
                                    Text("+\(me.phoneNumber)")
                                }
                                Divider()
                            }
                            Button { showProfile = true } label: {
                                Label(L10n.t("Common.Profile"), systemImage: "person.crop.circle")
                            }
                            Button { showAccounts = true } label: {
                                Label("Аккаунты", systemImage: "person.2")
                            }
                            Button { showProxy = true } label: {
                                Label(L10n.t("Common.Proxy"), systemImage: "network")
                            }
                            Button { showSettings = true } label: {
                                Label(L10n.t("Common.Settings"), systemImage: "gearshape")
                            }
                            Button(role: .destructive) { confirmLogout = true } label: {
                                Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showProfile) { ProfileSettingsView() }
            .sheet(isPresented: $showVisitHistory) {
                LegacyVisitHistoryView { chatId in
                    showVisitHistory = false
                    openTarget = ChatTarget(chatId: chatId, messageId: nil)
                }
            }
            .sheet(isPresented: $showProxy) { ProxySettingsView() }
            .sheet(isPresented: $showAccounts) { AccountsView() }
            .sheet(isPresented: $showSearchHistory) {
                SearchHistoryView { item in search = item }
            }
            .sheet(isPresented: $showNewChat) {
                ChatPickerView(title: "Новое сообщение") { chatId in
                    openTarget = ChatTarget(chatId: chatId, messageId: nil)
                }
            }
            .sheet(item: $createKind) { kind in
                CreateChatView(kind: kind) { chatId in
                    openTarget = ChatTarget(chatId: chatId, messageId: nil)
                }
            }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { client.logOut() }
            }
            .background(link)
        }
        .navigationViewStyle(.stack)
    }

    private var link: some View {
        NavigationLink(
            destination: Group {
                if let target = openTarget {
                    ChatView(chatId: target.chatId, focusMessageId: target.messageId)
                }
            },
            isActive: Binding(get: { openTarget != nil }, set: { if !$0 { openTarget = nil } })
        ) { EmptyView() }
        .hidden()
    }

    private func row(_ chat: ChatItem) -> some View {
        HStack(spacing: 12) {
            LegacyAvatarView(id: chat.id, title: chat.title, photo: chat.photo, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(aliases.chatAlias(chat.id) ?? chat.title)
                        .font(.headline)
                        .lineLimit(1)
                    if chat.id == savedId {
                        Text("Избранное").font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundColor(.accentColor)
                    } else if chat.id == store.lastOpenedChatId {
                        Text("Недавний").font(.caption2).foregroundColor(.secondary)
                    }
                }
                Text(preview(chat))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let date = chat.lastMessage.map({ MessageFormatter.listDate($0.date) }) {
                    Text(date).font(.caption2).foregroundColor(.secondary)
                }
                if let presence = presence(chat) {
                    Text(presence)
                        .font(.caption2)
                        .foregroundColor(presence == "в сети" ? .green : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if chat.unreadCount > 0 {
                Text("\(chat.unreadCount)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func isPinned(_ chat: ChatItem) -> Bool {
        chat.id == savedId || chat.isPinned || store.isLocallyPinned(chat.id)
    }

    private func scheduleSearch() {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { searchRows = []; return }
        // Local chats appear immediately and stay even if network search is slow.
        var immediate: [LegacySearchRow] = store.mainChatIds.compactMap { chatId in
            guard let chat = store.chats[chatId] else { return nil }
            let title = aliases.chatAlias(chat.id) ?? chat.title
            return title.localizedCaseInsensitiveContains(text) ? .chat(chatId) : nil
        }
        searchRows = immediate
        Task {
            var rows: [LegacySearchRow] = []
            let settings = Self.settingsItems.filter {
                $0.1.contains { $0.localizedCaseInsensitiveContains(text) }
            }.map { LegacySearchRow.setting($0.0) }
            rows += settings
            var contacts = (try? await client.searchContacts(text)) ?? []
            let digits = text.filter { $0.isNumber }
            if digits.count >= 3 {
                for user in store.users.values where !contacts.contains(where: { $0.id == user.id }) {
                    let phone = user.phoneNumber.filter { $0.isNumber }
                    if !phone.isEmpty && (phone.hasPrefix(digits) || phone.hasSuffix(digits) || phone.contains(digits)) {
                        contacts.append(user)
                    }
                }
            }
            rows += contacts.map { .contact($0) }
            let channels = (try? await client.searchChannels(text)) ?? []
            rows += channels.compactMap { store.chats[$0] }.map { .chat($0.id) }
            let saved = client.me?.id
            let messages = (try? await client.searchMessages(text)) ?? []
            rows += messages.filter { $0.chatId != saved }.map { .message($0) }
            guard search.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            var seen = Set(immediate.map { $0.id })
            for row in immediate where !rows.contains(where: { $0.id == row.id }) {
                rows.insert(row, at: 0)
                seen.insert(row.id)
            }
            searchRows = rows
        }
    }

    private static let settingsItems: [(String, [String])] = [
        ("Прокси", ["прокси", "proxy"]),
        ("Настройки", ["настройки", "settings"]),
        ("Уведомления", ["уведомления", "notification"]),
        ("Оптимизация", ["оптимизация", "кэш", "cache"])
    ]

    @ViewBuilder
    private func rowView(_ row: LegacySearchRow) -> some View {
        switch row {
        case .setting(let name):
            Button {
                if name == "Прокси" { showProxy = true } else { showSettings = true }
            } label: { Label(name, systemImage: "gearshape") }
        case .contact(let user):
            Button {
                Task {
                    if let chatId = try? await client.openChat(userId: user.id) {
                        openTarget = ChatTarget(chatId: chatId, messageId: nil)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    LegacyAvatarView(
                        id: user.id,
                        title: [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "),
                        file: user.profilePhoto?.big,
                        size: 40
                    )
                    Text([user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "))
                        .lineLimit(1)
                    Spacer()
                }
            }
        case .chat(let chatId):
            Button { openTarget = ChatTarget(chatId: chatId, messageId: nil) } label: {
                HStack(spacing: 10) {
                    LegacyAvatarView(
                        id: chatId,
                        title: store.chats[chatId]?.title ?? "Чат",
                        photo: store.chats[chatId]?.photo,
                        size: 40
                    )
                    Text(store.chats[chatId]?.title ?? "Чат").lineLimit(1)
                    Spacer()
                }
            }
        case .message(let message):
            Button { openTarget = ChatTarget(chatId: message.chatId, messageId: message.id) } label: {
                HStack(spacing: 10) {
                    LegacyAvatarView(
                        id: message.chatId,
                        title: store.chats[message.chatId]?.title ?? "Чат",
                        photo: store.chats[message.chatId]?.photo,
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.chats[message.chatId]?.title ?? "Чат").font(.appCaption.bold())
                        Text(MessageFormatter.preview(message.content)).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
    }

    private func presence(_ chat: ChatItem) -> String? {
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

    private func preview(_ chat: ChatItem) -> String {
        if let action = store.actionText(chatId: chat.id) { return action }
        guard let message = chat.lastMessage else { return "Нет сообщений" }
        let text = MessageFormatter.preview(message.content)
        if message.isOutgoing && !chat.isChannel { return "Вы: \(text)" }
        return text
    }

    private func initials(_ title: String) -> String {
        let letters = title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private func color(_ id: Int64) -> Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal]
        return palette[Int(abs(id % Int64(palette.count)))]
    }
}

enum LegacySearchRow: Identifiable {
    case setting(String)
    case contact(TDLibKit.User)
    case chat(Int64)
    case message(TDLibKit.Message)

    var id: String {
        switch self {
        case .setting(let name): return "s-\(name)"
        case .contact(let user): return "u-\(user.id)"
        case .chat(let id): return "c-\(id)"
        case .message(let message): return "m-\(message.chatId)-\(message.id)"
        }
    }
}
