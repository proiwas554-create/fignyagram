import SwiftUI
import UIKit
import Combine
import TDLibKit

struct ChatView: View {
    let chatId: Int64

    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared
    @StateObject private var voice = VoiceRecorder()

    @State private var text = ""
    @State private var didInitialScroll = false
    @State private var olderAnchorId: Int64?
    @State private var scrollTarget: Int64?

    @State private var replyTo: Message?
    @State private var editing: Message?
    @State private var actionMessage: Message?
    @State private var forwardMessage: Message?
    @State private var showPhotoPicker = false
    @State private var showDocumentPicker = false
    @State private var showVideoNoteRecorder = false
    @State private var preparingMedia = 0

    private var chat: ChatItem? { store.chats[chatId] }
    private var messages: [Message] { store.messages[chatId] ?? [] }
    private var isLoading: Bool { store.loadingChats.contains(chatId) }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let error = client.errorMessage {
                ErrorBanner(message: error)
                    .padding(.vertical, 4)
                    .onTapGesture { client.errorMessage = nil }
            }
            if store.canWrite(chatId: chatId) {
                Divider()
                inputArea
            } else if chat?.isChannel == true {
                Divider()
                Text("Публиковать в этом канале могут только администраторы")
                    .font(.footnote).foregroundColor(.secondary)
                    .padding(10)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(chat?.title ?? "Чат").font(.headline).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption2)
                            .foregroundColor(store.actionText(chatId: chatId) != nil ? .accentColor : .secondary)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if let chat { AvatarView(id: chat.id, title: chat.title, photo: chat.photo, size: 32) }
            }
        }
        .onAppear { client.openChat(chatId) }
        .onDisappear {
            client.closeChat(chatId)
            if voice.isRecording { voice.cancel() }
            AudioPlayback.shared.stop()
        }
        .sheet(item: Binding(get: { actionMessage.map(Identified.init) }, set: { actionMessage = $0?.message })) { item in
            MessageActionsSheet(message: item.message) { handle($0, for: item.message) }
        }
        .sheet(item: Binding(get: { forwardMessage.map(Identified.init) }, set: { forwardMessage = $0?.message })) { item in
            ChatPickerView(title: "Переслать") { target in
                client.forward(item.message, to: target)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { providers in sendPicked(providers) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { urls in sendDocuments(urls) }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showVideoNoteRecorder) {
            VideoNoteRecorderView { prepared in
                client.sendVideoNote(prepared.url, duration: prepared.duration, length: prepared.width, to: chatId, replyTo: takeReply())
            }
        }
    }

    // MARK: - Messages

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
                            isRead: message.id <= (chat?.lastReadOutboxMessageId ?? 0),
                            onReply: { startReply(message) },
                            onLongPress: { actionMessage = message },
                            onReplyTap: { scrollTarget = $0 }
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
            .onChange(of: scrollTarget) { target in
                guard let target else { return }
                if messages.contains(where: { $0.id == target }) {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                } else {
                    client.errorMessage = "Сообщение ещё не загружено — пролистайте выше"
                }
                scrollTarget = nil
            }
        }
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
                        Text(MessageFormatter.preview(banner.content)).font(.caption).lineLimit(1)
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
    }

    private var bannerMessage: Message? { editing ?? replyTo }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if editing == nil {
                Menu {
                    Button { showPhotoPicker = true } label: { Label("Фото или видео", systemImage: "photo") }
                    Button { showDocumentPicker = true } label: { Label("Файл", systemImage: "doc") }
                } label: {
                    Group {
                        if preparingMedia > 0 {
                            ProgressView()
                        } else {
                            Image(systemName: "paperclip").font(.system(size: 22))
                        }
                    }
                    .frame(width: 32, height: 36)
                }
            }

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
            .onChange(of: text) { newValue in
                if !newValue.isEmpty && editing == nil { client.sendChatAction(.chatActionTyping, chatId: chatId) }
            }

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editing != nil {
                Button(action: sendText) {
                    Image(systemName: editing != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
            } else {
                Button(action: startVoice) {
                    Image(systemName: "mic").font(.system(size: 22)).frame(width: 32, height: 36)
                }
                Button { showVideoNoteRecorder = true } label: {
                    Image(systemName: "video.circle").font(.system(size: 24)).frame(width: 32, height: 36)
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

    private func sendText() {
        if let editing {
            client.editMessage(editing, text: text)
            self.editing = nil
        } else {
            client.sendText(text, to: chatId, replyTo: takeReply())
        }
        text = ""
    }

    private func takeReply() -> Int64? {
        defer { replyTo = nil }
        return replyTo?.id
    }

    private func startReply(_ message: Message) {
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

    private func handle(_ action: MessageAction, for message: Message) {
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
        case .delete(let forAll):
            client.deleteMessages(chatId: chatId, ids: [message.id], forAll: forAll)
        }
    }

    /// Photos and videos from the picker; the typed text becomes the caption of the first item.
    private func sendPicked(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let firstCaption = text
        text = ""
        let reply = takeReply()
        preparingMedia += providers.count
        Task {
            var caption = firstCaption
            for provider in providers {
                let itemCaption = caption
                caption = ""
                if provider.hasItemConformingToTypeIdentifier("public.movie") {
                    client.sendChatAction(.chatActionUploadingVideo(ChatActionUploadingVideo(progress: 0)), chatId: chatId)
                    if let source = await MediaPreparer.loadMovie(provider), let video = await MediaPreparer.video(source) {
                        client.sendVideo(video.url, width: video.width, height: video.height, duration: video.duration,
                                         caption: itemCaption, to: chatId, replyTo: reply)
                    } else {
                        client.errorMessage = "Не удалось подготовить видео"
                    }
                } else if let image = await MediaPreparer.loadImage(provider), let photo = MediaPreparer.photo(image) {
                    client.sendPhoto(photo.url, width: photo.width, height: photo.height, caption: itemCaption, to: chatId, replyTo: reply)
                } else {
                    client.errorMessage = "Не удалось открыть фото"
                }
                preparingMedia -= 1
            }
        }
    }

    private func sendDocuments(_ urls: [URL]) {
        let reply = takeReply()
        var caption = text
        text = ""
        for url in urls {
            if let copy = MediaPreparer.document(url) {
                client.sendDocument(copy, caption: caption, to: chatId, replyTo: reply)
                caption = ""
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
        guard let last = messages.last?.id else { return }
        if animated {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
        didInitialScroll = true
    }
}

/// Wraps a message for `.sheet(item:)`.
struct Identified: Identifiable {
    let message: Message
    var id: Int64 { message.id }
}
