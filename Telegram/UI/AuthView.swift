import SwiftUI
import TDLibKit

struct AuthView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var proxy = BuiltInProxyManager.shared
    @ObservedObject private var accounts = AccountStore.shared

    @State private var phone = ""
    @State private var code = ""
    @State private var email = ""
    @State private var emailCode = ""
    @State private var password = ""
    @State private var firstName = ""
    @State private var lastName = ""
    /// Lets the user go back to the phone number screen from later steps.
    @State private var editingPhone = false
    @State private var showProxy = false
    @State private var showQRScanner = false
    @State private var stalled = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header.padding(.top, 60)
                if stalled {
                    stallCard
                }
                accountEscape
                if !proxy.isEnabled {
                    Button {
                        proxy.setEnabled(true)
                    } label: {
                        Label("Включить прокси для входа", systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    showQRScanner = true
                } label: {
                    Label("Сканировать QR-код для входа", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                content
                ErrorBanner(message: client.errorMessage)
                if client.isBusy { ProgressView() }
                Button {
                    showProxy = true
                } label: {
                    Label(proxy.isEnabled ? "Прокси включён" : "Настроить прокси",
                          systemImage: "network")
                        .font(.appFootnote)
                }
                .padding(.top, 8)
            }
            .padding()
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showProxy) {
            ProxySettingsView()
        }
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerSheet { code in
                client.confirmQrLogin(code)
            }
        }
        .onChange(of: client.authStep) { _ in
            editingPhone = false
            code = ""
            emailCode = ""
            password = ""
        }
        .task(id: client.isBusy) {
            guard client.isBusy else { stalled = false; return }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, client.isBusy else { return }
            stalled = true
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, client.isBusy, proxy.isEnabled, stalled else { return }
            // Automatic rescue: a dead proxy must not lock the login screen.
            proxy.setEnabled(false)
            client.restartConnection()
        }
    }

    /// Always visible near the top so a mistaken "add account" can be undone,
    /// even if the previous-account marker was lost.
    @ViewBuilder
    private var accountEscape: some View {
        if let target = escapeAccount {
            Button {
                if accounts.previousId != nil {
                    client.cancelAddAccount()
                } else {
                    client.switchAccount(to: target.id)
                }
            } label: {
                Label("Вернуться в «\(target.title)»", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var escapeAccount: AccountSlot? {
        if let previousId = accounts.previousId,
           let previous = accounts.accounts.first(where: { $0.id == previousId }) {
            return previous
        }
        return accounts.accounts.first(where: { $0.id != accounts.currentId })
    }

    private var stallCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Подключение зависло", systemImage: "exclamationmark.triangle.fill")
                .font(.appHeadline)
                .foregroundColor(.orange)
            Text(proxy.lastError ?? "Прокси не отвечает. Можно войти напрямую или перезапустить подключение.")
                .font(.appFootnote)
                .foregroundColor(.secondary)
            HStack {
                Button("Войти без прокси") {
                    proxy.setEnabled(false)
                    stalled = false
                    client.restartConnection()
                }
                .buttonStyle(.borderedProminent)
                Button("Перезапустить") {
                    stalled = false
                    client.restartConnection()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("🦋").font(.system(size: 80))
            Text("Fignyagram")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            AppVersionLabel()
        }
    }

    @ViewBuilder
    private var content: some View {
        if editingPhone {
            phoneForm
        } else {
            switch client.authStep {
            case .initializing:
                VStack(spacing: 12) {
                    ProgressView("Подключение…")
                    Button("Отмена") {
                        proxy.setEnabled(false)
                        client.restartConnection()
                    }
                    .font(.appFootnote)
                }
            case .phone:
                phoneForm
            case .code(let info):
                codeForm(info)
            case .emailAddress:
                emailForm
            case .emailCode(let info):
                emailCodeForm(info)
            case .registration:
                registrationForm
            case .password(let hint):
                passwordForm(hint: hint)
            case .qrCode(let link):
                qrForm(link: link)
            case .premiumRequired:
                Text("Для входа с этого номера Telegram требует подписку Premium. Оформите её в официальном приложении.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            case .loggingOut:
                ProgressView("Выход…")
            case .ready:
                ProgressView()
            }
        }
    }

    private var phoneForm: some View {
        VStack(spacing: 14) {
            Text("Введите номер телефона").font(.appHeadline)
            Text("Номер в международном формате, например +79991234567")
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            TextField("+7 999 123 45 67", text: $phone)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            Button {
                client.sendPhoneNumber(phone)
            } label: {
                Text("Далее").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(phone.isEmpty || client.isBusy)

            Button("Войти по QR-коду") { client.requestQrCode() }
                .disabled(client.isBusy)
        }
    }

    private func codeForm(_ info: TDLibKit.AuthenticationCodeInfo) -> some View {
        VStack(spacing: 14) {
            Text("Введите код").font(.appHeadline)
            Text("\(Self.codeDestination(info.type)) на номер \(info.phoneNumber)")
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            TextField("Код", text: $code)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button {
                client.sendCode(code)
            } label: {
                Text("Подтвердить").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.isEmpty || client.isBusy)

            if let next = info.nextType {
                Button("Отправить код \(Self.codeDestination(next).lowercased())") { client.resendCode() }
                    .disabled(client.isBusy)
            }
            Button("Другой номер") { editingPhone = true }
        }
    }

    private var emailForm: some View {
        VStack(spacing: 14) {
            Text("Укажите email").font(.appHeadline)
            Text("Telegram требует почту для входа с нового устройства")
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            TextField("email@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
            Button {
                client.sendEmail(email)
            } label: {
                Text("Далее").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || client.isBusy)
        }
    }

    private func emailCodeForm(_ info: TDLibKit.EmailAddressAuthenticationCodeInfo) -> some View {
        VStack(spacing: 14) {
            Text("Код из письма").font(.appHeadline)
            Text("Отправлен на \(info.emailAddressPattern)")
                .font(.appFootnote).foregroundColor(.secondary)
            TextField("Код", text: $emailCode)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button {
                client.sendEmailCode(emailCode)
            } label: {
                Text("Подтвердить").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(emailCode.isEmpty || client.isBusy)
        }
    }

    private var registrationForm: some View {
        VStack(spacing: 14) {
            Text("Новый аккаунт").font(.appHeadline)
            TextField("Имя", text: $firstName).textFieldStyle(.roundedBorder).textContentType(.givenName)
            TextField("Фамилия (необязательно)", text: $lastName).textFieldStyle(.roundedBorder).textContentType(.familyName)
            Button {
                client.register(firstName: firstName, lastName: lastName)
            } label: {
                Text("Зарегистрироваться").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(firstName.isEmpty || client.isBusy)
        }
    }

    private func passwordForm(hint: String) -> some View {
        VStack(spacing: 14) {
            Text("Облачный пароль").font(.appHeadline)
            Text("На аккаунте включена двухэтапная аутентификация")
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            SecureField(hint.isEmpty ? "Пароль" : "Подсказка: \(hint)", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
            Button {
                client.sendPassword(password)
            } label: {
                Text("Войти").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || client.isBusy)
        }
    }

    private func qrForm(link: String) -> some View {
        VStack(spacing: 14) {
            Text("Вход по QR-коду").font(.appHeadline)
            Text("Откройте Telegram на другом устройстве → Настройки → Устройства → Подключить устройство и отсканируйте код")
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            if let image = QRCode.image(for: link) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(12)
            }
            Button("Войти по номеру телефона") { editingPhone = true }
        }
    }

    static func codeDestination(_ type: TDLibKit.AuthenticationCodeType) -> String {
        switch type {
        case .authenticationCodeTypeTelegramMessage: return "Код отправлен в приложение Telegram"
        case .authenticationCodeTypeSms, .authenticationCodeTypeSmsWord, .authenticationCodeTypeSmsPhrase: return "Код отправлен по SMS"
        case .authenticationCodeTypeCall: return "Код продиктуют в звонке"
        case .authenticationCodeTypeFlashCall, .authenticationCodeTypeMissedCall: return "Код — последние цифры входящего звонка"
        case .authenticationCodeTypeFragment: return "Код отправлен через Fragment"
        default: return "Код отправлен"
        }
    }
}
