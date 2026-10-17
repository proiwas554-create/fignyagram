import SwiftUI
import UIKit
import Combine
import TDLibKit

struct MessageRow: View {
    let message: Message
    let showSender: Bool
    let isRead: Bool
    var onReply: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onReplyTap: (Int64) -> Void = { _ in }

    @ObservedObject private var store = ChatStore.shared
    @State private var dragOffset: CGFloat = 0

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
                reactions
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
            if showSender && !message.isOutgoing {
                Text(store.senderName(message.senderId))
                    .font(.caption.bold())
                    .foregroundColor(.accentColor)
            }
            if let forward = message.forwardInfo {
                Text("Переслано от \(store.originName(forward.origin))")
                    .font(.caption2).italic().opacity(0.85)
            }
            replyHeader
            MessageContentView(message: message)
            if let caption = MessageFormatter.caption(of: message.content), !caption.text.isEmpty {
                Text(MessageFormatter.attributed(caption))
            }
            reactions
            footer
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
    private var replyHeader: some View {
        if case .messageReplyToMessage(let reply) = message.replyTo {
            let chatId = reply.chatId == 0 ? message.chatId : reply.chatId
            let replied = store.message(chatId: chatId, id: reply.messageId)
            let name = replied.map { store.senderName($0.senderId) } ?? reply.origin.map { store.originName($0) } ?? "Сообщение"
            let text = reply.quote?.text.text
                ?? replied.map { MessageFormatter.preview($0.content) }
                ?? reply.content.map { MessageFormatter.preview($0) }
                ?? "…"
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.caption.bold())
                    Text(text).font(.caption).lineLimit(1).opacity(0.85)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
            .onTapGesture { onReplyTap(reply.messageId) }
            .onAppear {
                if replied == nil && reply.content == nil {
                    TelegramClient.shared.loadMessage(chatId: chatId, id: reply.messageId)
                }
            }
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
                            .font(.caption)
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

    private var footer: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            if message.editDate > 0 { Text("изм.") }
            Text(MessageFormatter.time(message.date))
            if message.isOutgoing { statusIcon }
        }
        .font(.caption2)
        .opacity(0.7)
        .fixedSize()
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

/// Media part of a message.
struct MessageContentView: View {
    let message: Message

    var body: some View {
        switch message.content {
        case .messagePhoto(let p):
            PhotoView(photo: p.photo)
        case .messageVideo(let v):
            VideoView(video: v.video)
        case .messageAnimation(let a):
            AnimationView(animation: a.animation)
        case .messageSticker(let s):
            StickerView(sticker: s.sticker)
        case .messageAnimatedEmoji(let e):
            Text(e.emoji).font(.system(size: 64))
        case .messageVoiceNote(let v):
            VoiceNoteView(note: v.voiceNote, isOutgoing: message.isOutgoing)
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
                Text(label).font(.callout)
            }
        }
    }
}

enum MessageAction {
    case reply, copy, edit, forward
    case react(ReactionType)
    case delete(forAll: Bool)
}

/// Long-press menu: reactions plus the actions TDLib allows for this message.
struct MessageActionsSheet: View {
    let message: Message
    let onAction: (MessageAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reactions: [ReactionType] = []
    @State private var properties: MessageProperties?
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
                }
                Section {
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
