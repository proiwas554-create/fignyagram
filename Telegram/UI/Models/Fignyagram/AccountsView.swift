import SwiftUI

/// Plain account switcher (Telegram-style): current account, other accounts,
/// add account and cancel a pending login. No profile data here.
struct AccountsView: View {
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(AccountManager.shared.profiles) { account in
                        Button {
                            if account.id != accounts.currentId {
                                client.switchAccount(to: account.id)
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: account.id == accounts.currentId ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(account.id == accounts.currentId ? .accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.title)
                                        .foregroundColor(.primary)
                                    Text(account.id == accounts.currentId ? "Текущий аккаунт" : "Нажмите, чтобы переключиться")
                                        .font(.appCaption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .contextMenu {
                            if account.id != accounts.currentId {
                                Button {
                                    client.switchAccount(to: account.id)
                                    dismiss()
                                } label: {
                                    Label("Переключиться", systemImage: "arrow.left.arrow.right")
                                }
                            }
                            if account.id == accounts.currentId {
                                Button(role: .destructive) {
                                    client.logOut()
                                    dismiss()
                                } label: {
                                    Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            } else {
                                Button(role: .destructive) {
                                    accounts.remove(id: account.id)
                                } label: {
                                    Label("Удалить из списка", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        client.addAccount()
                        dismiss()
                    } label: {
                        Label("Добавить аккаунт", systemImage: "plus.circle")
                    }
                    if accounts.previousId != nil {
                        Button {
                            client.cancelAddAccount()
                            dismiss()
                        } label: {
                            Label("Вернуться в предыдущий аккаунт", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
            .navigationTitle("Аккаунты")
            .modifier(GlassListModifier())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
