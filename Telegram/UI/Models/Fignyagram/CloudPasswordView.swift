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
                            Button("Отключить облачный пароль", role: .destructive) {
                                showDisable = true
                            }
                        }
                    } else {
                        setupSection
                    }
                } else {
                    Text("Не удалось загрузить состояние пароля")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Облачный пароль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .task { await load() }
            .confirmationDialog(
                "Отключить облачный пароль?",
                isPresented: $showDisable,
                titleVisibility: .visible
            ) {
                Button("Отключить", role: .destructive) { disablePassword() }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text("Для отключения введите текущий пароль в поле «Текущий пароль».")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func statusSection(_ state: PasswordState) -> some View {
        Section {
            HStack {
                Text("Двухэтапная проверка")
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
                Text("Резервная почта привязана")
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var setupSection: some View {
        Section {
            SecureField("Новый пароль", text: $newPassword)
            SecureField("Повторите пароль", text: $confirmPassword)
            TextField("Подсказка (необязательно)", text: $hint)
            TextField("Резервная почта (необязательно)", text: $recoveryEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Установить пароль") { save() }
                .disabled(isSaving || !canSubmit)
        } footer: {
            Text("Пароль запрашивается при входе в аккаунт на новом устройстве.")
                .font(.appFootnote)
        }
    }

    private var changeSection: some View {
        Section {
            SecureField("Текущий пароль", text: $oldPassword)
            SecureField("Новый пароль", text: $newPassword)
            SecureField("Повторите новый пароль", text: $confirmPassword)
            TextField("Новая подсказка", text: $hint)
            Button("Сохранить пароль") { save() }
                .disabled(isSaving || oldPassword.isEmpty || !canSubmit)
        } header: {
            Text("Изменить пароль")
        } footer: {
            Text("Чтобы отключить пароль, оставьте новые поля пустыми и подтвердите действие.")
                .font(.appFootnote)
        }
    }

    private var resetSection: some View {
        Section {
            if !showReset {
                Button("Забыли пароль?") {
                    showReset = true
                }
            } else {
                if !resetRequested {
                    Button("Отправить код на резервную почту") {
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
                    TextField("Код из письма", text: $resetCode)
                        .keyboardType(.numberPad)
                    SecureField("Новый пароль", text: $newPassword)
                    SecureField("Повторите пароль", text: $confirmPassword)
                    TextField("Новая подсказка", text: $hint)
                    Button("Сбросить пароль") { recover() }
                        .disabled(isSaving || resetCode.isEmpty || !canSubmit)
                }
            }
        } header: {
            Text("Восстановление")
        } footer: {
            Text("Если пароль забыт, код придёт на почту, которую вы привязали заранее.")
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
