import SwiftUI
import TDLibKit

struct ClassicProfileMenuView: View {
    let onSettings: () -> Void
    let onLogout: () -> Void

    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var accounts = AccountStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if let me = client.me {
                    Section {
                        VStack(alignment: .leading, spacing: 3) {
                            Text([me.firstName, me.lastName].filter { !$0.isEmpty }.joined(separator: " "))
                                .font(.appHeadline)
                            if !me.phoneNumber.isEmpty {
                                Text("+\(me.phoneNumber)")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Menu {
                        ForEach(accounts.accounts) { account in
                            Button {
                                client.switchAccount(to: account.id)
                                dismiss()
                            } label: {
                                Label(
                                    account.title,
                                    systemImage: account.id == accounts.currentId ? "checkmark.circle.fill" : "circle"
                                )
                            }
                        }
                        Button {
                            client.addAccount()
                            dismiss()
                        } label: {
                            Label(L10n.t("Auto.5253f2060d"), systemImage: "plus.circle")
                        }
                    } label: {
                        HStack {
                            Label(L10n.t("Auto.d699f70d7f"), systemImage: "person.2")
                            Spacer()
                            Image(systemName: "chevron.right").font(.appCaption).foregroundColor(.secondary)
                        }
                    }

                    Button {
                        dismiss()
                        onSettings()
                    } label: {
                        HStack {
                            Label(L10n.t("Common.Settings"), systemImage: "gearshape")
                            Spacer()
                            Image(systemName: "chevron.right").font(.appCaption).foregroundColor(.secondary)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        dismiss()
                        onLogout()
                    } label: {
                        Label(L10n.t("Auto.0f05cf8ab6"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("Common.Profile"))
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
