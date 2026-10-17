import SwiftUI
import TDLibKit

struct ChatView: View {
    let chatId: Int64

    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared

    @State private var text = ""
    @State private var didInitialScroll = false
    @State private var olderAnchorId: Int64?

    private var chat: ChatItem? { store.chats[chatId] }
    private var messages: [Message] { store.messages[chatId] ?? [] }
    private var isLoading: Bool { store.loadingChats.contains(chatId) }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if chat?.isChannel != true {
                Divider()
                inputBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(chat?.title ?? "Чат").font(.headline).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if let chat { AvatarView(id: chat.id, title: chat.title, photo: chat.photo, size: 32) }
            }
        }
        .onAppear { client.openChat(chatId) }
        .onDisappear { client.closeChat(chatId) }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if !messages.isEmpty && !store.fullyLoadedChats.contains(chatId) {
                        ProgressView()
                            .padding()
                            .onAppear {
                                olderAnchorId = messages.first?.id
                                client.loadOlderMessages(chatId: chatId)
                            }
                    }
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            showSender: chat?.isGroup == true,
                            isRead: message.id <= (chat?.lastReadOutboxMessageId ?? 0)
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .overlay {
                if messages.isEmpty {
                    if isLoading {
                        ProgressView("Загрузка…")
                    } else {
                        VStack(spacing: 12) {
                            Text("Сообщений нет").foregroundColor(.secondary)
                            Button("Обновить") { client.loadHistory(chatId: chatId) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: messages.last?.id) { _ in
                scrollToBottom(proxy, animated: didInitialScroll)
            }
            .onChange(of: messages.first?.id) { _ in
                if let anchor = olderAnchorId {
                    proxy.scrollTo(anchor, anchor: .top)
                    olderAnchorId = nil
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if #available(iOS 16.0, *) {
                    TextField("Сообщение", text: $text, axis: .vertical).lineLimit(1...5)
                } else {
                    TextField("Сообщение", text: $text)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))

            Button {
                client.sendMessage(chatId: chatId, text: text)
                text = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        guard let chat else { return "" }
        if let userId = chat.privateUserId, let user = store.users[userId] {
            if case .userTypeBot = user.type { return "бот" }
            return MessageFormatter.userStatus(user.status)
        }
        if chat.isChannel { return "канал" }
        if chat.isGroup { return "группа" }
        return ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last?.id else { return }
        if animated {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
        didInitialScroll = true
    }
}

struct MessageRow: View {
    let message: Message
    let showSender: Bool
    let isRead: Bool

    @ObservedObject private var store = ChatStore.shared

    var body: some View {
        if let service = MessageFormatter.serviceText(message.content) {
            Text(service)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            HStack {
                if message.isOutgoing { Spacer(minLength: 48) }
                bubble
                if !message.isOutgoing { Spacer(minLength: 48) }
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showSender && !message.isOutgoing {
                Text(store.senderName(message.senderId))
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
            }
            if message.forwardInfo != nil {
                Text("Пересланное сообщение").font(.caption2).italic().opacity(0.8)
            }
            if case .messagePhoto(let p) = message.content {
                PhotoView(photo: p.photo)
            } else if let label = MessageFormatter.mediaLabel(message.content) {
                Text(label).font(.callout)
            }
            if let caption = MessageFormatter.caption(of: message.content), !caption.text.isEmpty {
                Text(MessageFormatter.attributed(caption))
                    .textSelection(.enabled)
            }
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                if message.editDate > 0 { Text("изм.") }
                Text(MessageFormatter.time(message.date))
                if message.isOutgoing { statusIcon }
            }
            .font(.caption2)
            .opacity(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundColor(message.isOutgoing ? .white : .primary)
        .tint(message.isOutgoing ? .white : .accentColor)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(message.isOutgoing ? Color.accentColor : Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.sendingState {
        case .messageSendingStatePending:
            Image(systemName: "clock")
        case .messageSendingStateFailed:
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
        case nil:
            Text(isRead ? "✓✓" : "✓")
        }
    }
}

struct PhotoView: View {
    let photo: Photo
    @ObservedObject private var store = ChatStore.shared

    private var size: PhotoSize? {
        let sorted = photo.sizes.sorted { $0.width < $1.width }
        return sorted.last { $0.width <= 800 } ?? sorted.first
    }

    var body: some View {
        let aspect = size.map { CGFloat(max($0.width, 1)) / CGFloat(max($0.height, 1)) } ?? 1
        Group {
            if let size, let path = store.localPath(size.photo), let image = ImageCache.image(atPath: path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let thumb = ImageCache.image(minithumbnail: photo.minithumbnail) {
                Image(uiImage: thumb).resizable().scaledToFill().blur(radius: 6)
                    .overlay(ProgressView())
            } else {
                Color.gray.opacity(0.2).overlay(ProgressView())
            }
        }
        .frame(width: 240, height: min(max(240 / aspect, 80), 360))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if let size { TelegramClient.shared.download(size.photo, priority: 16) }
        }
    }
}
