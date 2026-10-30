import SwiftUI

struct WatchChatView: View {
    let chat: WatchChat
    @StateObject private var bridge = WatchBridgeManager.shared
    @State private var replyText = ""
    @State private var showReply = false
    @State private var templates: [String] = []

    private var messages: [WatchMessage] { bridge.messages[chat.id] ?? [] }

    var body: some View {
        List {
            ForEach(messages) { message in
                bubble(message)
            }
            if messages.isEmpty {
                Text(L10n.t("Watch.NoMessages"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                showReply = true
            } label: {
                Label(L10n.t("Watch.Reply"), systemImage: "arrowshape.turn.up.left.fill")
                    .font(.footnote)
            }
            .buttonStyle(.borderedProminent)
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showReply) {
            WatchReplyView(chat: chat, templates: templates, replyText: $replyText)
        }
        .onAppear {
            bridge.requestMessages(chatId: chat.id, limit: 40)
            bridge.requestTemplates()
        }
        .onChange(of: bridge.templates) { value in templates = value }
    }

    private func bubble(_ message: WatchMessage) -> some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 12) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if !message.isOutgoing {
                    Text(message.senderName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                Text(message.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(message.isOutgoing ? Color.accentColor : Color.gray.opacity(0.25))
                    )
                    .foregroundColor(message.isOutgoing ? .white : .primary)
            }
            if !message.isOutgoing { Spacer(minLength: 12) }
        }
    }
}

struct WatchReplyView: View {
    let chat: WatchChat
    let templates: [String]
    @Binding var replyText: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = WatchBridgeManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                TextField(L10n.t("Watch.TypeMessage"), text: $replyText)
                    .textFieldStyle(.plain)
                ForEach(templates.prefix(3), id: \.self) { template in
                    Button(template) { replyText = template }
                        .font(.footnote)
                        .lineLimit(1)
                }
                Button(L10n.t("Watch.Send")) {
                    let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    bridge.sendWatchMessage(chatId: chat.id, text: text)
                    replyText = ""
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 6)
    }
}
