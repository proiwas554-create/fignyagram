import SwiftUI
import TDLibKit

/// Recent global-search queries. Available in both design modes via the clock
/// button in the chat list header.
struct SearchHistoryView: View {
    @ObservedObject private var history = SearchHistory.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var recent = RecentContactsStore.shared
    @ObservedObject private var contacts = ContactsSync.shared
    @AppStorage("recentContactsEnabled") private var contactsEnabledFromServer = true
    @AppStorage("recentContactsEnabled") private var recentContactsEnabled = true
    @Environment(\.dismiss) private var dismiss
    var onPick: (String) -> Void
    var onOpenContact: ((Int64) -> Void)? = nil

    /// Server contacts minus the ones already listed as recent.
    private var serverContacts: [Int64] {
        let recentIds = Set(recent.userIds)
        return contacts.serverContactIds
            .filter { !recentIds.contains($0) && store.users[$0] != nil }
            .prefix(120)
            .map { $0 }
    }

    private static func displayName(_ user: TDLibKit.User) -> String {
        let name = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        return user.usernames?.activeUsernames.first ?? "Контакт"
    }

    var body: some View {
        NavigationView {
            List {
                if recentContactsEnabled, !recent.userIds.isEmpty {
                    Section("Недавние контакты") {
                        ForEach(recent.userIds, id: \.self) { userId in
                            if let user = store.users[userId] {
                                Button {
                                    onOpenContact?(userId)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        LegacyAvatarView(
                                            id: userId,
                                            title: [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "),
                                            file: user.profilePhoto?.big,
                                            size: 34
                                        )
                                        Text([user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "))
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        recent.remove(userId)
                                    } label: {
                                        Label("Убрать", systemImage: "person.badge.minus")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        recent.remove(userId)
                                    } label: {
                                        Label("Убрать из недавних", systemImage: "person.badge.minus")
                                    }
                                }
                            }
                        }
                    }
                }
                if recentContactsEnabled, contactsEnabledFromServer, !serverContacts.isEmpty {
                    Section("Контакты Telegram") {
                        ForEach(serverContacts, id: \.self) { userId in
                            if let user = store.users[userId] {
                                Button {
                                    onOpenContact?(userId)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        LegacyAvatarView(
                                            id: userId,
                                            title: Self.displayName(user),
                                            file: user.profilePhoto?.big,
                                            size: 34
                                        )
                                        Text(Self.displayName(user))
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "checkmark.seal")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if history.items.isEmpty {
                    Text("История поиска пуста")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history.items, id: \.self) { item in
                        Button {
                            onPick(item)
                            dismiss()
                        } label: {
                            Label(item, systemImage: "clock.arrow.circlepath")
                                .foregroundColor(.primary)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            history.remove(history.items[index])
                        }
                    }
                }
            }
            .navigationTitle("История поиска")
            .modifier(GlassListModifier())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !history.items.isEmpty {
                        Button("Очистить", role: .destructive) { history.clear() }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
