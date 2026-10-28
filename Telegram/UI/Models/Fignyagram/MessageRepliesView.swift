import SwiftUI
import TDLibKit

struct MessageRepliesView: View {
    let chatId: Int64
    let messageId: Int64
    let onSelect: (Int64) -> Void

    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [TDLibKit.Message] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView(NSLocalizedString("Generated.ea068feb6bc9", comment: ""))
                } else if let errorText {
                    Text(errorText)
                        .foregroundColor(.secondary)
                        .padding()
                } else if messages.isEmpty {
                    Text(L10n.t("Auto.72f6db2ff3"))
                        .foregroundColor(.secondary)
                } else {
                    List(messages, id: \.id) { message in
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                onSelect(message.id)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(store.senderName(message.senderId))
                                        .font(.caption.bold())
                                        .foregroundColor(.accentColor)
                                    Spacer()
                                    Text(MessageFormatter.time(message.date))
                                        .font(.appCaption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(MessageFormatter.preview(message.content))
                                    .font(.appSubheadline)
                                    .foregroundColor(.primary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("Auto.27b2fd7f31"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .task { await load() }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        isLoading = true
        messages = await TelegramClient.shared.messageThread(chatId: chatId, messageId: messageId)
        isLoading = false
    }
}
