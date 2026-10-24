import SwiftUI
import TDLibKit

/// List of all pinned messages in a chat. TDLib supports multiple pins via
/// the pinned-message search filter.
struct PinnedMessagesView: View {
    let chatId: Int64
    let onSelect: (Int64) -> Void

    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dismiss) private var dismiss

    private var pinned: [TDLibKit.Message] {
        store.pinnedMessages(chatId: chatId)
    }

    var body: some View {
        NavigationView {
            List {
                if pinned.isEmpty {
                    Text("В этом чате нет закреплённых сообщений")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(pinned, id: \.id) { message in
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onSelect(message.id)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pin.fill")
                                        .font(.appCaption)
                                        .foregroundColor(.orange)
                                    Text(store.senderName(message.senderId))
                                        .font(.caption.bold())
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                Text(MessageFormatter.preview(message.content))
                                    .font(.appSubheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                TelegramClient.shared.unpinMessage(message)
                            } label: {
                                Label("Открепить", systemImage: "pin.slash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Закреплённые")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onAppear {
                TelegramClient.shared.loadPinnedMessages(chatId: chatId)
            }
        }
        .navigationViewStyle(.stack)
    }
}
