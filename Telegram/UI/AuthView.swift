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
                        Label(L10n.t("Auto.cd120292f5"), systemImage: "network")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    showQRScanner = true
                } label: {
                    Label(L10n.t("Auto.f1f0dc55ce"), systemImage: "qrcode.viewfinder")
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
            Label(L10n.t("Auto.841f592c32"), systemImage: "exclamationmark.triangle.fill")
                .font(.appHeadline)
                .foregroundColor(.orange)
            Text(proxy.lastError ?? "Прокси не отвечает. Можно войти напрямую или перезапустить подключение.")
                .font(.appFootnote)
                .foregroundColor(.secondary)
            HStack {
                Button(L10n.t("Auto.4c0352f9e6")) {
                    proxy.setEnabled(false)
                    stalled = false
                    client.restartConnection()
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.t("Auto.4f8110f3d7")) {
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
                    Button(L10n.t("Common.Cancel")) {
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
                Text(L10n.t("Auto.e795bc484a"))
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
            Text(L10n.t("Auto.cc031a9155")).font(.appHeadline)
            Text(L10n.t("Auto.309fdf0839"))
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            TextField("+7 999 123 45 67", text: $phone)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            Button {
                client.sendPhoneNumber(phone)
            } label: {
                Text(L10n.t("Auto.c453091253")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(phone.isEmpty || client.isBusy)

            Button(L10n.t("Auto.9631fc9963")) { client.requestQrCode() }
                .disabled(client.isBusy)
        }
    }

    private func codeForm(_ info: TDLibKit.AuthenticationCodeInfo) -> some View {
        VStack(spacing: 14) {
            Text(L10n.t("Auto.3c41d442de")).font(.appHeadline)
            Text("\(Self.codeDestination(info.type)) на номер \(info.phoneNumber)")
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            TextField(L10n.t("Auto.3f34a617ce"), text: $code)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button {
                client.sendCode(code)
            } label: {
                Text(L10n.t("Auto.e2603bcce7")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.isEmpty || client.isBusy)

            if let next = info.nextType {
                Button("Отправить код \(Self.codeDestination(next).lowercased())") { client.resendCode() }
                    .disabled(client.isBusy)
            }
            Button(L10n.t("Auto.e74fdbe75f")) { editingPhone = true }
        }
    }

    private var emailForm: some View {
        VStack(spacing: 14) {
            Text(L10n.t("Auto.87285e0948")).font(.appHeadline)
            Text(L10n.t("Auto.9e7cc5b5f5"))
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            TextField("email@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
            Button {
                client.sendEmail(email)
            } label: {
                Text(L10n.t("Auto.c453091253")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(email.isEmpty || client.isBusy)
        }
    }

    private func emailCodeForm(_ info: TDLibKit.EmailAddressAuthenticationCodeInfo) -> some View {
        VStack(spacing: 14) {
            Text(L10n.t("Auto.0e6ee45cf3")).font(.appHeadline)
            Text("Отправлен на \(info.emailAddressPattern)")
                .font(.appFootnote).foregroundColor(.secondary)
            TextField(L10n.t("Auto.3f34a617ce"), text: $emailCode)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
            Button {
                client.sendEmailCode(emailCode)
            } label: {
                Text(L10n.t("Auto.e2603bcce7")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(emailCode.isEmpty || client.isBusy)
        }
    }

    private var registrationForm: some View {
        VStack(spacing: 14) {
            Text(L10n.t("Auto.1bb53524f7")).font(.appHeadline)
            TextField(L10n.t("Auto.d38d6d925c"), text: $firstName).textFieldStyle(.roundedBorder).textContentType(.givenName)
            TextField(L10n.t("Auto.de830cd96b"), text: $lastName).textFieldStyle(.roundedBorder).textContentType(.familyName)
            Button {
                client.register(firstName: firstName, lastName: lastName)
            } label: {
                Text(L10n.t("Auto.fb9e993e98")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(firstName.isEmpty || client.isBusy)
        }
    }

    private func passwordForm(hint: String) -> some View {
        VStack(spacing: 14) {
            Text(L10n.t("Auto.5a77c57a29")).font(.appHeadline)
            Text(L10n.t("Auto.383e346138"))
                .font(.appFootnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            SecureField(hint.isEmpty ? "Пароль" : "Подсказка: \(hint)", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
            Button {
                client.sendPassword(password)
            } label: {
                Text(L10n.t("Auto.63a753751e")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || client.isBusy)
        }
    }

    private func qrForm(link: String) -> some View {
        VStack(spacing: 14) {
            Text(L10n.t("Auto.8a3c96389c")).font(.appHeadline)
            Text(L10n.t("Auto.1a435ad693"))
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
            Button(L10n.t("Auto.128576be08")) { editingPhone = true }
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
