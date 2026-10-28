import SwiftUI
import TDLibKit

struct DirectMessageStatsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case latest, unread, frequent
        var id: String { rawValue }
        var title: String {
            switch self {
            case .latest: return "Последний"
            case .unread: return "Непрочитанные"
            case .frequent: return "Чаще пишут"
            }
        }
    }

    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var aliases = LocalAliases.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .latest
    @State private var selectedChatId: Int64?

    private var privateChats: [ChatItem] {
        store.chats.values.filter { $0.privateUserId != nil }
    }

    private var latestIncoming: [ChatItem] {
        privateChats
            .filter { $0.lastMessage?.isOutgoing == false }
            .sorted { ($0.lastMessage?.date ?? 0) > ($1.lastMessage?.date ?? 0) }
    }

    private var unread: [ChatItem] {
        privateChats
            .filter { $0.unreadCount > 0 }
            .sorted { ($0.lastMessage?.date ?? 0) > ($1.lastMessage?.date ?? 0) }
    }

    private var frequent: [(ChatItem, Int)] {
        privateChats.compactMap { chat in
            let count = (store.messages[chat.id] ?? []).filter { !$0.isOutgoing }.count
            return count > 0 ? (chat, count) : nil
        }
        .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)

                List {
                    switch mode {
                    case .latest:
                        ForEach(latestIncoming) { chat in
                            row(chat, detail: dateText(chat.lastMessage?.date))
                        }
                    case .unread:
                        ForEach(unread) { chat in
                            row(chat, detail: "\(chat.unreadCount) непрочитанных")
                        }
                    case .frequent:
                        ForEach(frequent, id: \.0.id) { chat, count in
                            row(chat, detail: "\(count) входящих")
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Личные сообщения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { selectedChatId.map(SelectedChat.init) },
                set: { selectedChatId = $0?.id }
            )) { target in
                NavigationView {
                    ChatView(chatId: target.id)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.t("Common.Close")) { selectedChatId = nil }
                            }
                        }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ chat: ChatItem, detail: String) -> some View {
        Button {
            selectedChatId = chat.id
        } label: {
            HStack(spacing: 12) {
                AvatarView(id: chat.id, title: chat.title, photo: chat.photo, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(aliases.chatAlias(chat.id) ?? chat.title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func dateText(_ unix: Int?) -> String {
        guard let unix, unix > 0 else { return "нет сообщений" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}

private struct SelectedChat: Identifiable {
    let id: Int64
}
