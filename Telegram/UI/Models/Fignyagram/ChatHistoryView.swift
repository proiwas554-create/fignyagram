import SwiftUI

struct ChatHistoryView: View {
    let onSelect: (Int64) -> Void

    @ObservedObject private var history = ChatVisitHistory.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var aliases = LocalAliases.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if history.visits.isEmpty {
                    Text(L10n.t("Auto.eb556d7cf5"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history.visits) { visit in
                        if let chat = store.chats[visit.chatId] {
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    onSelect(chat.id)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    AvatarView(id: chat.id, title: chat.title, photo: chat.photo, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(aliases.chatAlias(chat.id) ?? chat.title)
                                            .font(.subheadline.bold())
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(String(format: L10n.t("AutoI.0c8cd78c7b"), String(describing: visit.visits)))
                                            .font(.appCaption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(L10n.t("Auto.817d7c3aa6"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !history.visits.isEmpty {
                        Button(L10n.t("Auto.7074366a75"), role: .destructive) {
                            history.clear()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func dateText(_ date: Foundation.Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
