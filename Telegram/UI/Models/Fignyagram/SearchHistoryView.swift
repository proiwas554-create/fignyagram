import SwiftUI
import TDLibKit

/// Recent global-search queries. Available in both design modes via the clock
/// button in the chat list header.
struct SearchHistoryView: View {
    @ObservedObject private var history = SearchHistory.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var recent = RecentContactsStore.shared
    @AppStorage("recentContactsEnabled") private var recentContactsEnabled = true
    @Environment(\.dismiss) private var dismiss
    var onPick: (String) -> Void
    var onOpenContact: ((Int64) -> Void)? = nil

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
                    Button("Закрыть") { dismiss() }
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
