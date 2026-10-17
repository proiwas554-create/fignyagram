import SwiftUI
import TDLibKit

struct ChatListView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared

    @State private var search = ""
    @State private var confirmLogout = false

    private var chatIds: [Int64] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.mainChatIds }
        return store.mainChatIds.filter { store.chats[$0]?.title.localizedCaseInsensitiveContains(query) == true }
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(chatIds, id: \.self) { chatId in
                    if let chat = store.chats[chatId] {
                        NavigationLink(destination: ChatView(chatId: chatId)) {
                            ChatRow(chat: chat)
                        }
                        .onAppear {
                            if chatId == store.mainChatIds.last { client.loadMoreChats() }
                        }
                    }
                }
                if client.isLoadingChats {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Поиск чатов")
            .overlay {
                if store.mainChatIds.isEmpty && !client.isLoadingChats {
                    VStack(spacing: 12) {
                        Text("🦋").font(.system(size: 60)).opacity(0.6)
                        Text("Чатов пока нет").foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Fignyagram")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if let me = client.me {
                            Text([me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " "))
                            if !me.phoneNumber.isEmpty { Text("+\(me.phoneNumber)") }
                        }
                        Button(role: .destructive) {
                            confirmLogout = true
                        } label: {
                            Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { client.logOut() }
            }
            .safeAreaInset(edge: .bottom) {
                ErrorBanner(message: client.errorMessage)
                    .onTapGesture { client.errorMessage = nil }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct ChatRow: View {
    let chat: ChatItem
    @ObservedObject private var store = ChatStore.shared

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(id: chat.id, title: chat.title, photo: chat.photo)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if chat.isChannel { Image(systemName: "megaphone.fill").font(.caption).foregroundColor(.secondary) }
                    else if chat.isGroup { Image(systemName: "person.2.fill").font(.caption).foregroundColor(.secondary) }
                    Text(chat.title).font(.headline).lineLimit(1)
                    Spacer()
                    if let message = chat.lastMessage {
                        if message.isOutgoing {
                            Text(message.id <= chat.lastReadOutboxMessageId ? "✓✓" : "✓")
                                .font(.caption).foregroundColor(.accentColor)
                        }
                        Text(MessageFormatter.listDate(message.date))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(preview).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                    Spacer()
                    if chat.unreadCount > 0 || chat.isMarkedAsUnread {
                        Text(chat.unreadCount > 0 ? "\(chat.unreadCount)" : " ")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor))
                    } else if chat.isPinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        guard let message = chat.lastMessage else { return "" }
        let text = MessageFormatter.preview(message.content)
        if MessageFormatter.serviceText(message.content) != nil { return text }
        if message.isOutgoing && !chat.isChannel { return "Вы: \(text)" }
        if chat.isGroup { return "\(store.senderName(message.senderId)): \(text)" }
        return text
    }
}
