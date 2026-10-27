import SwiftUI
import UIKit
import Combine
import TDLibKit


/// Formatting results are expensive (entity parsing, attributed strings) and
/// are recomputed for every visible row on each SwiftUI pass. Cache them per
/// message revision so scrolling and incoming updates stay cheap.
private enum MessageFormatCache {
    private static let storage: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 600
        return cache
    }()

    final class Box: NSObject {
        let value: Any
        init(_ value: Any) { self.value = value }
    }

    static func key(_ message: TDLibKit.Message, _ kind: String) -> NSString {
        "\(message.chatId):\(message.id):\(message.editDate ?? 0):\(kind)" as NSString
    }

    static func value<T>(for message: TDLibKit.Message, kind: String, make: () -> T) -> T {
        let cacheKey = key(message, kind)
        if let box = storage.object(forKey: cacheKey), let value = box.value as? T {
            return value
        }
        let value = make()
        storage.setObject(Box(value), forKey: cacheKey)
        return value
    }
}

private extension TDLibKit.Message {
    var cachedServiceText: String? {
        MessageFormatCache.value(for: self, kind: "service") { MessageFormatter.serviceText(content) }
    }
    var cachedPreview: String {
        MessageFormatCache.value(for: self, kind: "preview") { MessageFormatter.preview(content) }
    }
    var cachedCaption: TDLibKit.FormattedText? {
        MessageFormatCache.value(for: self, kind: "caption") { MessageFormatter.caption(of: content) }
    }
}

struct MessageRow: View {
    let message: TDLibKit.Message
    let showSender: Bool
    let isRead: Bool
    /// Resolved by the parent so rows don't observe the whole store.
    let senderName: String
    let forwardedFrom: String?
    var onReply: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onReplyTap: (Int64) -> Void = { _ in }
    var onSenderTap: (MessageSender) -> Void = { _ in }
    var onOpenReplies: () -> Void = {}
    var onRetry: () -> Void = {}

    @State private var dragOffset: CGFloat = 0
    @State private var senderTag: TelegramClient.MemberTagInfo?
    @State private var showTagEditor = false
    @State private var myTagDraft = ""
    @State private var longTextPayload: LongTextPayload?
    @State private var secretMediaURL: URL?

    @AppStorage("showAdminAuthors") private var showAdminAuthors = true
    @AppStorage("hideSenderNames") private var hideSenderNames = false
    @ObservedObject private var ultra = UltraMode.shared
    @ObservedObject private var classic = ClassicDesignMode.shared

    /// The peer a "call ended" service message belongs to, so tapping it can
    /// call back.
    private var callMessageUserId: Int64? {
        guard case .messageCall = message.content else { return nil }
        if let chat = ChatStore.shared.chats[message.chatId],
           case .chatTypePrivate(let info) = chat.type {
            return info.userId
        }
        if case .messageSenderUser(let sender) = message.senderId {
            return sender.userId
        }
        return nil
    }

    var body: some View {
        if let service = message.cachedServiceText {
            Text(service)
                .font(.appCaption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Capsule())
                .onTapGesture {
                    guard let userId = callMessageUserId else { return }
                    let isVideo: Bool
                    if case .messageCall(let call) = message.content {
                        isVideo = call.isVideo
                    } else {
                        isVideo = false
                    }
                    TelegramClient.shared.callUser(userId: userId, isVideo: isVideo)
                }
        } else {
            HStack {
                if message.isOutgoing { Spacer(minLength: 48) }
                content
                if !message.isOutgoing { Spacer(minLength: 48) }
            }
            .offset(x: dragOffset)
            .background(alignment: .trailing) {
                if dragOffset < -10 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundColor(.secondary)
                        .opacity(Double(min(1, -dragOffset / 60)))
                }
            }
            .contentShape(Rectangle())
            .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name("fignyagramMemberTagChanged"))) { note in
                guard let chatId = note.userInfo?["chatId"] as? Int64,
                      let userId = note.userInfo?["userId"] as? Int64,
                      chatId == message.chatId,
                      case .messageSenderUser(let sender) = message.senderId,
                      sender.userId == userId else { return }
                Task {
                    senderTag = await TelegramClient.shared.memberTagInfo(
                        chatId: message.chatId, userId: userId
                    )
                }
            }
            .task(id: "\(message.chatId):\(message.id)") {
                guard !ultra.isEnabled, showSender, !message.isOutgoing,
                      case .messageSenderUser(let sender) = message.senderId else {
                    senderTag = nil
                    return
                }
                senderTag = await TelegramClient.shared.memberTagInfo(
                    chatId: message.chatId, userId: sender.userId
                )
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onLongPress()
            }
            .simultaneousGesture(swipeToReply)
        }
    }

    private var swipeToReply: some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { value in
                let w = value.translation.width
                guard w < 0, abs(w) > abs(value.translation.height) * 2 else { return }
                dragOffset = max(w, -70)
            }
            .onEnded { _ in
                if dragOffset <= -55 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onReply()
                }
                withAnimation(.spring()) { dragOffset = 0 }
            }
    }

    /// Stickers and round videos are shown without a bubble.
    private var isBare: Bool {
        switch message.content {
        case .messageSticker, .messageVideoNote, .messageAnimatedEmoji: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        if isBare {
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                replyHeader
                MessageContentView(message: message)
                if !ultra.isEnabled { reactions }
                repliesButton
                footer
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
            }
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !hideSenderNames && !showSender && !message.authorSignature.isEmpty && showAdminAuthors {
                Text(message.authorSignature)
                    .font(.caption.bold())
                    .foregroundColor(.green)
                    .lineLimit(1)
            }
            if showSender && !message.isOutgoing && !hideSenderNames {
                HStack(spacing: 5) {
                    Button {
                        onSenderTap(message.senderId)
                    } label: {
                        Text(senderName)
                            .font(.caption.bold())
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    if let senderTag, !senderTag.text.isEmpty {
                        Text(senderTag.text)
                            .font(.appCaption)
                            .italic()
                            .lineLimit(1)
                            .foregroundColor(senderTag.isAdmin ? .green : .accentColor)
                            .onTapGesture {
                                myTagDraft = TelegramClient.shared.me.map { _ in "" } ?? ""
                                showTagEditor = true
                            }
                    }
                }
            }
            if let forwardedFrom, !hideSenderNames {
                Text("Переслано от \(forwardedFrom)")
                    .font(.appCaption2).italic().opacity(0.85)
            }
            replyHeader
            MessageContentView(message: message)
            if case .messageText(let textContent) = message.content,
               !textContent.text.text.isEmpty,
               textContent.text.text.count <= 4000 {
                TranslatedTextView(
                    text: textContent.text.text,
                    font: .appCaption2.italic()
                )
            }
            if let caption = message.cachedCaption, !caption.text.isEmpty {
                SpoilerTextView(formatted: caption)
                TranslatedTextView(
                    text: caption.text,
                    font: .appCaption2.italic()
                )
            }
            if !ultra.isEnabled { reactions }
            repliesButton
            footer
        }
        .sheet(item: $longTextPayload) { payload in
            LongTextSheet(text: payload.text)
        }
        .sheet(isPresented: $showTagEditor) {
            NavigationView {
                Form {
                    Section {
                        TextField("Мой тег", text: $myTagDraft)
                            .textInputAutocapitalization(.never)
                    } footer: {
                        Text("Тег виден участникам этого чата. Пустое поле убирает тег.")
                            .font(.appFootnote)
                    }
                }
                .navigationTitle("Задать мой тег")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") { showTagEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") {
                            Task {
                                if let me = TelegramClient.shared.me {
                                    try? await TelegramClient.shared.setMemberTag(
                                        chatId: message.chatId, userId: me.id, tag: myTagDraft
                                    )
                                }
                                showTagEditor = false
                            }
                        }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundColor(message.isOutgoing ? .white : .primary)
        .tint(message.isOutgoing ? .white : .accentColor)
        .background(
            RoundedRectangle(cornerRadius: classic.isEnabled ? 14 : 20)
                .fill(message.isOutgoing ? Color.accentColor : Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private var replyHeader: some View {
        if case .messageReplyToMessage(let reply) = message.replyTo {
            MessageReplyHeader(chatId: message.chatId, reply: reply) { onReplyTap($0) }
        }
    }

    @ViewBuilder
    private var reactions: some View {
        if let list = message.interactionInfo?.reactions?.reactions, !list.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(list, id: \.type) { reaction in
                    Button {
                        TelegramClient.shared.toggleReaction(reaction.type, on: message)
                    } label: {
                        Text("\(MessageFormatter.reactionLabel(reaction.type)) \(reaction.totalCount)")
                            .font(.appCaption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(reaction.isChosen ? Color.blue.opacity(0.85) : Color.primary.opacity(0.12)))
                            .foregroundColor(reaction.isChosen ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 120)
        }
    }

    @ViewBuilder
    private var repliesButton: some View {
        if let info = message.interactionInfo?.replyInfo, info.replyCount > 0 {
            Button {
                onOpenReplies()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.2")
                    Text("\(info.replyCount) \(info.replyCount == 1 ? "ответ" : "ответов")")
                }
                .font(.appCaption)
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            if message.editDate > 0 { Text("изм.") }
            Text(MessageFormatter.time(message.date))
            if message.isOutgoing { statusIcon }
        }
        .font(.appCaption2)
        .opacity(0.7)
        .fixedSize()
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.sendingState {
        case .messageSendingStatePending:
            Image(systemName: "clock")
        case .messageSendingStateFailed(let failure):
            Button {
                if failure.canRetry { onRetry() }
            } label: {
                Image(systemName: failure.canRetry ? "arrow.clockwise.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(failure.canRetry ? "Отправить ещё раз" : "Ошибка отправки")
        case nil:
            Text(isRead ? "✓✓" : "✓")
        }
    }
}

/// Reply preview. Observes the store on its own so the whole message row doesn't.
private struct MessageReplyHeader: View {
    let chatId: Int64
    let reply: TDLibKit.MessageReplyToMessage
    let onTap: (Int64) -> Void

    @ObservedObject private var store = ChatStore.shared

    var body: some View {
        let targetChatId = reply.chatId == 0 ? chatId : reply.chatId
        let replied = store.message(chatId: targetChatId, id: reply.messageId)
        let blocked = replied.map { store.isSenderBlocked($0.senderId) } ?? false
        let name = blocked
            ? "Заблокированный пользователь"
            : (replied.map { store.senderName($0.senderId) } ?? reply.origin.map { store.originName($0) } ?? "Сообщение")
        let text = blocked
            ? "Скрыто"
            : (reply.quote?.text.text
                ?? replied.map(\.cachedPreview)
                ?? reply.content.map { MessageFormatter.preview($0) }
                ?? "…")
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption.bold())
                Text(text).font(.appCaption).lineLimit(1).opacity(0.85)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
        .onTapGesture { onTap(reply.messageId) }
        .onAppear {
            if replied == nil && reply.content == nil {
                TelegramClient.shared.loadMessage(chatId: targetChatId, id: reply.messageId)
            }
        }
    }
}

/// Media part of a message.
struct MessageContentView: View {
    let message: TDLibKit.Message

    var body: some View {
        switch message.content {
        case .messagePhoto(let p):
            PhotoView(
                photo: p.photo,
                chatId: message.chatId,
                messageId: message.id,
                hasSpoiler: p.hasSpoiler
            )
        case .messageVideo(let v):
            VideoView(
                video: v.video,
                chatId: message.chatId,
                messageId: message.id,
                hasSpoiler: v.hasSpoiler
            )
        case .messageAnimation(let a):
            AnimationView(gif: a.animation)
        case .messageSticker(let s):
            StickerView(sticker: s.sticker)
        case .messageAnimatedEmoji(let e):
            Text(e.emoji).font(.system(size: 64))
        case .messageVoiceNote(let v):
            VoiceNoteView(note: v.voiceNote, isOutgoing: message.isOutgoing)
        case .messagePoll(let poll):
            PollMessageView(
                chatId: message.chatId,
                messageId: message.id,
                content: poll,
                isOutgoing: message.isOutgoing
            )
        case .messageAudio(let a):
            AudioFileView(audio: a.audio, isOutgoing: message.isOutgoing)
        case .messageVideoNote(let v):
            VideoNoteView(note: v.videoNote)
        case .messageDocument(let d):
            DocumentView(document: d.document, isOutgoing: message.isOutgoing)
        case .messageText:
            EmptyView()
        default:
            if let label = MessageFormatter.mediaLabel(message.content) {
                Text(label).font(.appCallout)
            }
        }
    }
}

struct PollMessageView: View {
    let chatId: Int64
    let messageId: Int64
    let content: TDLibKit.MessagePoll
    let isOutgoing: Bool

    @State private var selected: Set<Int> = []

    private var poll: TDLibKit.Poll { content.poll }

    private var canVote: Bool {
        poll.voteRestrictionReason == nil && !poll.isClosed
    }

    private var showsResults: Bool {
        poll.isClosed || poll.canSeeResults || poll.options.contains(where: { $0.isChosen })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.question.text)
                .font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                Button {
                    choose(index)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(option.text.text)
                                .font(.appSubheadline)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if showsResults {
                                Text("\(option.votePercentage)%")
                                    .font(.caption.monospacedDigit())
                                    .opacity(0.8)
                            }
                        }
                        if showsResults {
                            ProgressView(value: Double(option.votePercentage) / 100)
                                .tint(isOutgoing ? .white : .accentColor)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                option.isChosen || selected.contains(index)
                                    ? (isOutgoing ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.18))
                                    : Color.primary.opacity(0.07)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canVote)
            }

            if poll.allowsMultipleAnswers, canVote, !selected.isEmpty {
                Button("Голосовать") {
                    TelegramClient.shared.votePoll(
                        chatId: chatId,
                        messageId: messageId,
                        optionIds: selected.sorted()
                    )
                    selected.removeAll()
                }
                .font(.footnote.bold())
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                Text("\(poll.totalVoterCount) голосов")
                if poll.isAnonymous { Text("анонимный") }
                if poll.isClosed { Text("закрыт") }
                if let reason = poll.voteRestrictionReason {
                    Text("голосование недоступно")
                }
            }
            .font(.appCaption2)
            .opacity(0.7)
        }
        .padding(.vertical, 2)
    }

    private func choose(_ index: Int) {
        guard canVote else { return }
        if poll.allowsMultipleAnswers {
            if selected.contains(index) {
                selected.remove(index)
            } else {
                selected.insert(index)
            }
        } else {
            TelegramClient.shared.votePoll(
                chatId: chatId,
                messageId: messageId,
                optionIds: [index]
            )
        }
    }
}


/// Efficient viewer for very long messages: UIKit's text view handles huge
/// strings without the layout cost that SwiftUI Text pays on every pass.
struct LongTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            LongTextView(text: text)
                .navigationTitle("Сообщение")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

struct LongTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

/// Attributed text is rebuilt for every visible row pass; entity parsing is the
/// expensive part, so results are cached by text revision.
private enum AttributedTextCache {
    final class Box: NSObject { let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    private static let storage: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()

    static func value(for formatted: TDLibKit.FormattedText) -> AttributedString {
        let key = "\(formatted.text.hashValue):\(formatted.text.count):\(formatted.entities.count)" as NSString
        if let box = storage.object(forKey: key) { return box.value }
        let value = MessageFormatter.attributed(formatted)
        storage.setObject(Box(value), forKey: key)
        return value
    }
}

struct SpoilerTextView: View {
    let formatted: TDLibKit.FormattedText
    @State private var revealed = false
    @State private var showFullText = false

    private static let inlineLimit = 4000

    private var isHuge: Bool { formatted.text.count > Self.inlineLimit }

    private var preview: String {
        String(formatted.text.prefix(Self.inlineLimit))
    }

    private var hasSpoiler: Bool {
        formatted.entities.contains {
            if case .textEntityTypeSpoiler = $0.type { return true }
            return false
        }
    }

    var body: some View {
        if isHuge {
            VStack(alignment: .leading, spacing: 6) {
                Text(preview)
                    .modifier(SelectableTextModifier())
                    .fixedSize(horizontal: false, vertical: true)
                Text("… ещё \(formatted.text.count - Self.inlineLimit) символов")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                Button("Показать полностью") { showFullText = true }
                    .font(.appCaption.bold())
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            }
            .sheet(isPresented: $showFullText) {
                LongTextSheet(text: formatted.text)
            }
        } else if hasSpoiler && !revealed {
            Text(formatted.text)
                .modifier(SelectableTextModifier())
                .foregroundColor(.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.16))
                        .overlay(
                            Text("Спойлер")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        )
                }
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) { revealed = true }
                }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(AttributedTextCache.value(for: formatted))
                .modifier(SelectableTextModifier())
                .onTapGesture {
                    if hasSpoiler { revealed = false }
                }
        }
    }
}

enum MessageAction {
    case reply, copy, edit, forward
    case saveToSaved
    case react(TDLibKit.ReactionType)
    case addToMusic(TDLibKit.Audio)
    case pin(isPinned: Bool)
    case saveMedia
    case saveSticker
    case saveStickerPack
    case replies
    case favoriteAnimation
    case sendAnimationSticker
    case saveGif
    case setMemberTag(userId: Int64)
    case quote(String)
    case translate(String)
    case stickerSet(TdInt64)
    case call(phoneNumber: String)
    case block(userId: Int64, isBlocked: Bool)
    case delete(forAll: Bool)
}

/// Long-press menu: reactions plus the actions TDLib allows for this message.
struct MessageActionsSheet: View {
    let message: TDLibKit.Message
    let onAction: (MessageAction) -> Void

    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reactions: [TDLibKit.ReactionType] = []
    @State private var properties: TDLibKit.MessageProperties?
    @State private var loaded = false

    var body: some View {
        NavigationView {
            List {
                if !reactions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(reactions, id: \.self) { type in
                                Button { act(.react(type)) } label: {
                                    Text(MessageFormatter.reactionLabel(type)).font(.system(size: 30))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    if properties?.canBeReplied ?? true {
                        Button { act(.reply) } label: { Label("Ответить", systemImage: "arrowshape.turn.up.left") }
                    }
                    if let text = MessageFormatter.caption(of: message.content)?.text, !text.isEmpty {
                        Button { act(.copy) } label: { Label("Копировать", systemImage: "doc.on.doc") }
                    }
                    if properties?.canBeEdited == true {
                        Button { act(.edit) } label: { Label("Изменить", systemImage: "pencil") }
                    }
                    if properties?.canBeForwarded == true {
                        Button { act(.forward) } label: { Label("Переслать", systemImage: "arrowshape.turn.up.right") }
                    }
                    if case .messageAudio(let audio) = message.content {
                        Button { act(.addToMusic(audio.audio)) } label: {
                            Label("Добавить в плеер", systemImage: "music.note.list")
                        }
                    }
                    if (message.interactionInfo?.replyInfo?.replyCount ?? 0) > 0 {
                        Button { act(.replies) } label: {
                            Label("Посмотреть ответы", systemImage: "arrowshape.turn.up.left.2")
                        }
                    }
                    if properties?.canBePinned == true {
                        let pinned = store.isMessagePinned(chatId: message.chatId, id: message.id)
                        Button {
                            act(.pin(isPinned: !pinned))
                        } label: {
                            Label(pinned ? "Открепить" : "Закрепить", systemImage: pinned ? "pin.slash" : "pin")
                        }
                    }
                    if case .messageSenderUser(let sender) = message.senderId,
                       sender.userId != TelegramClient.shared.me?.id {
                        Button {
                            act(.setMemberTag(userId: sender.userId))
                        } label: {
                            Label("Выдать тег", systemImage: "tag")
                        }
                    }
                    if case .messageSticker(let sticker) = message.content, sticker.sticker.setId != 0 {
                        Button {
                            act(.stickerSet(sticker.sticker.setId))
                        } label: {
                            Label("Просмотреть набор", systemImage: "square.grid.2x2")
                        }
                    }
                    if let text = MessageFormatter.caption(of: message.content)?.text, !text.isEmpty {
                        Button {
                            act(.quote(text))
                        } label: {
                            Label("Цитировать фрагмент", systemImage: "quote.bubble")
                        }
                        Button {
                            act(.translate(text))
                        } label: {
                            Label("Перевести", systemImage: "character.bubble")
                        }
                    }
                    if case .messageAnimation = message.content {
                        Button { act(.saveGif) } label: {
                            Label("Сохранить гифку", systemImage: "rectangle.stack.badge.plus")
                        }
                        Button { act(.favoriteAnimation) } label: {
                            Label("В избранные стикеры", systemImage: "star")
                        }
                        Button { act(.sendAnimationSticker) } label: {
                            Label("Отправить как стикер", systemImage: "face.smiling")
                        }
                    }
                    if case .messageSticker = message.content {
                        Button { act(.saveSticker) } label: {
                            Label("В избранные стикеры", systemImage: "star")
                        }
                        Button { act(.saveStickerPack) } label: {
                            Label("Установить стикерпак", systemImage: "square.stack.3d.down.right")
                        }
                    } else if message.content.saveableFile != nil,
                       (properties?.canBeSaved != false || PrivacyPreferences.shared.ignoreCopyProtection) {
                        Button { act(.saveMedia) } label: {
                            Label("Сохранить", systemImage: "square.and.arrow.down")
                        }
                    }
                }
                if !message.isOutgoing, case .messageSenderUser(let sender) = message.senderId {
                    Section {
                        if let user = store.users[sender.userId], !user.phoneNumber.isEmpty {
                            Button {
                                act(.call(phoneNumber: user.phoneNumber))
                            } label: {
                                Label("Позвонить", systemImage: "phone")
                            }
                        }
                        Button {
                            act(.block(userId: sender.userId,
                                       isBlocked: !store.isUserBlocked(sender.userId)))
                        } label: {
                            Label(
                                store.isUserBlocked(sender.userId) ? "Разблокировать" : "Заблокировать",
                                systemImage: store.isUserBlocked(sender.userId) ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark"
                            )
                        }
                    } footer: {
                        Text("Блокировка действует везде: в личных чатах, группах и каналах.")
                            .font(.appFootnote)
                    }
                }
                Section {
                    if message.chatId != TelegramClient.shared.me?.id {
                        Button { act(.saveToSaved) } label: {
                            Label("Сохранить в «Избранное»", systemImage: "bookmark")
                        }
                    }
                    if properties?.canBeDeletedForAllUsers == true {
                        Button(role: .destructive) { act(.delete(forAll: true)) } label: {
                            Label("Удалить у всех", systemImage: "trash")
                        }
                    }
                    if properties?.canBeDeletedOnlyForSelf == true {
                        Button(role: .destructive) { act(.delete(forAll: false)) } label: {
                            Label("Удалить у меня", systemImage: "trash")
                        }
                    }
                }
                if !loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .navigationTitle("Сообщение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
        .mediumSheet()
        .task {
            async let reactionList = TelegramClient.shared.availableReactions(for: message)
            async let props = TelegramClient.shared.properties(of: message)
            reactions = await reactionList
            properties = await props
            loaded = true
        }
    }

    private func act(_ action: MessageAction) {
        dismiss()
        onAction(action)
    }
}

extension MessageRow: Equatable {
    /// Closures are intentionally ignored: they only capture the message and
    /// mutate the same parent state, so equal messages render identically.
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message &&
        lhs.showSender == rhs.showSender &&
        lhs.isRead == rhs.isRead &&
        lhs.senderName == rhs.senderName &&
        lhs.forwardedFrom == rhs.forwardedFrom
    }
}


private struct LongTextPayload: Identifiable {
    let id = UUID()
    let text: String
}
