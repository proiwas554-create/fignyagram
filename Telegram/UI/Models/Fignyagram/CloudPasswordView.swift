import SwiftUI
import TDLibKit

struct CloudPasswordView: View {
    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var state: PasswordState?
    @State private var isLoading = true
    @State private var isSaving = false

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var hint = ""
    @State private var recoveryEmail = ""

    @State private var showReset = false
    @State private var resetCode = ""
    @State private var resetEmailPattern = ""
    @State private var resetRequested = false
    @State private var showDisable = false

    var body: some View {
        NavigationView {
            Form {
                if isLoading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else if let state {
                    statusSection(state)

                    if state.hasPassword {
                        changeSection
                        resetSection
                        Section {
                            Button(L10n.t("Auto.cf6defa853"), role: .destructive) {
                                showDisable = true
                            }
                        }
                    } else {
                        setupSection
                    }
                } else {
                    Text(L10n.t("Auto.7930ea6a43"))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("Auto.5a77c57a29"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .task { await load() }
            .confirmationDialog(L10n.t("Auto.420f12339f"),
                isPresented: $showDisable,
                titleVisibility: .visible
            ) {
                Button(L10n.t("Auto.b278285aef"), role: .destructive) { disablePassword() }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t("Auto.3fd310bfbb"))
            }
        }
        .navigationViewStyle(.stack)
    }

    private func statusSection(_ state: PasswordState) -> some View {
        Section {
            HStack {
                Text(L10n.t("Auto.2be9fce5be"))
                Spacer()
                Text(state.hasPassword ? "Включена" : "Выключена")
                    .foregroundColor(state.hasPassword ? .green : .secondary)
            }
            if state.hasPassword, !state.passwordHint.isEmpty {
                Text("Подсказка: \(state.passwordHint)")
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
            }
            if state.hasRecoveryEmailAddress {
                Text(L10n.t("Auto.faa814c89d"))
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var setupSection: some View {
        Section {
            SecureField("Новый пароль", text: $newPassword)
            SecureField("Повторите пароль", text: $confirmPassword)
            TextField(L10n.t("Auto.9b11400452"), text: $hint)
            TextField(L10n.t("Auto.abc95e528d"), text: $recoveryEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L10n.t("Auto.a5c96f7eb2")) { save() }
                .disabled(isSaving || !canSubmit)
        } footer: {
            Text(L10n.t("Auto.7be4b3b199"))
                .font(.appFootnote)
        }
    }

    private var changeSection: some View {
        Section {
            SecureField("Текущий пароль", text: $oldPassword)
            SecureField("Новый пароль", text: $newPassword)
            SecureField("Повторите новый пароль", text: $confirmPassword)
            TextField(L10n.t("Auto.69af60dcda"), text: $hint)
            Button(L10n.t("Auto.9ddb6c7f01")) { save() }
                .disabled(isSaving || oldPassword.isEmpty || !canSubmit)
        } header: {
            Text(L10n.t("Auto.66fe09f030"))
        } footer: {
            Text(L10n.t("Auto.f4246ba3a4"))
                .font(.appFootnote)
        }
    }

    private var resetSection: some View {
        Section {
            if !showReset {
                Button(L10n.t("Auto.38bb0dceae")) {
                    showReset = true
                }
            } else {
                if !resetRequested {
                    Button(L10n.t("Auto.80c7108e42")) {
                        Task {
                            do {
                                let info = try await client.requestPasswordRecovery()
                                resetEmailPattern = info.emailAddressPattern
                                resetRequested = true
                            } catch {
                                client.errorMessage = TelegramClient.describe(error)
                            }
                        }
                    }
                } else {
                    Text("Код отправлен на \(resetEmailPattern)")
                        .font(.appFootnote)
                    TextField(L10n.t("Auto.0e6ee45cf3"), text: $resetCode)
                        .keyboardType(.numberPad)
                    SecureField("Новый пароль", text: $newPassword)
                    SecureField("Повторите пароль", text: $confirmPassword)
                    TextField(L10n.t("Auto.69af60dcda"), text: $hint)
                    Button(L10n.t("Auto.8513955adb")) { recover() }
                        .disabled(isSaving || resetCode.isEmpty || !canSubmit)
                }
            }
        } header: {
            Text(L10n.t("Auto.a6822a598f"))
        } footer: {
            Text(L10n.t("Auto.4942872d4a"))
                .font(.appFootnote)
        }
    }

    private var canSubmit: Bool {
        newPassword == confirmPassword &&
        (!newPassword.isEmpty || state?.hasPassword == true)
    }

    private func load() async {
        state = try? await client.passwordState()
        isLoading = false
    }

    private func save() {
        guard canSubmit else { return }
        isSaving = true
        Task {
            do {
                let updated = try await client.updateCloudPassword(
                    oldPassword: oldPassword,
                    newPassword: newPassword,
                    hint: hint,
                    recoveryEmail: recoveryEmail,
                    setRecoveryEmail: !recoveryEmail.isEmpty
                )
                state = updated
                oldPassword = ""
                newPassword = ""
                confirmPassword = ""
                hint = ""
                recoveryEmail = ""
            } catch {
                client.errorMessage = TelegramClient.describe(error)
            }
            isSaving = false
        }
    }

    private func disablePassword() {
        guard !oldPassword.isEmpty else {
            client.errorMessage = "Введите текущий пароль"
            return
        }
        isSaving = true
        Task {
            do {
                let updated = try await client.updateCloudPassword(
                    oldPassword: oldPassword,
                    newPassword: "",
                    hint: "",
                    recoveryEmail: "",
                    setRecoveryEmail: false
                )
                state = updated
                oldPassword = ""
            } catch {
                client.errorMessage = TelegramClient.describe(error)
            }
            isSaving = false
        }
    }

    private func recover() {
        guard canSubmit else { return }
        isSaving = true
        Task {
            do {
                let updated = try await client.recoverCloudPassword(
                    code: resetCode,
                    newPassword: newPassword,
                    hint: hint
                )
                state = updated
                showReset = false
                resetRequested = false
                resetCode = ""
                newPassword = ""
                confirmPassword = ""
                hint = ""
            } catch {
                client.errorMessage = TelegramClient.describe(error)
            }
            isSaving = false
        }
    }
}
