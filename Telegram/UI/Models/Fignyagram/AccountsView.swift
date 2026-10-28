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
                                    Label(L10n.t("Auto.cdb3358d5c"), systemImage: "arrow.left.arrow.right")
                                }
                            }
                            if account.id == accounts.currentId {
                                Button(role: .destructive) {
                                    client.logOut()
                                    dismiss()
                                } label: {
                                    Label(L10n.t("Auto.6d4183b79b"), systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            } else {
                                Button(role: .destructive) {
                                    accounts.remove(id: account.id)
                                } label: {
                                    Label(L10n.t("Auto.50f4cfe1cc"), systemImage: "trash")
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
                        Label(L10n.t("Auto.5253f2060d"), systemImage: "plus.circle")
                    }
                    if accounts.previousId != nil {
                        Button {
                            client.cancelAddAccount()
                            dismiss()
                        } label: {
                            Label(L10n.t("Auto.fe51c6478d"), systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("Auto.d699f70d7f"))
            .modifier(GlassListModifier())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
