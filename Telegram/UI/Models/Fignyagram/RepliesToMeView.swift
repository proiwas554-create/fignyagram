import SwiftUI
import TDLibKit

struct RepliesToMeView: View {
    let chatId: Int64
    let replies: [TDLibKit.Message]
    let onSelect: (Int64) -> Void

    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List(replies) { reply in
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onSelect(reply.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(store.senderName(reply.senderId))
                                .font(.appSubheadline.bold())
                                .foregroundColor(.primary)
                            Spacer()
                            Text(replyDate(reply))
                                .font(.appCaption2)
                                .foregroundColor(.secondary)
                        }
                        Text(MessageFormatter.preview(reply.content))
                            .font(.appFootnote)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Ответы вам")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func replyDate(_ message: TDLibKit.Message) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.date)))
    }
}
