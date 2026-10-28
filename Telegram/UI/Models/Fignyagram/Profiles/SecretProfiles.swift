import Combine
import CryptoKit
import Foundation
import SwiftUI

/// Hashes for the two PINs. The hash (not the PIN) is stored, salted with the
/// profile slot, and compared in constant time.
@MainActor
final class PINVault {
    static let shared = PINVault()

    private enum Keys {
        static let enabled = "pinRouterEnabled"
        static let primary = "pinPrimaryHash"
        static let duress = "pinDuressHash"
        static let secretAccount = "pinSecretAccountId"
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    var secretAccountId: String? {
        get { UserDefaults.standard.string(forKey: Keys.secretAccount) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.secretAccount) }
    }

    var hasPrimaryPin: Bool { UserDefaults.standard.string(forKey: Keys.primary) != nil }
    var hasDuressPin: Bool { UserDefaults.standard.string(forKey: Keys.duress) != nil }

    func setPrimaryPin(_ pin: String) {
        UserDefaults.standard.set(Self.hash(pin, salt: "primary"), forKey: Keys.primary)
    }

    func setDuressPin(_ pin: String) {
        UserDefaults.standard.set(Self.hash(pin, salt: "duress"), forKey: Keys.duress)
    }

    func matchesPrimary(_ pin: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: Keys.primary) else { return false }
        return Self.constantTimeEqual(stored, Self.hash(pin, salt: "primary"))
    }

    func matchesDuress(_ pin: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: Keys.duress) else { return false }
        return Self.constantTimeEqual(stored, Self.hash(pin, salt: "duress"))
    }

    private static func hash(_ pin: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + ":" + pin).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == rhs.utf8.count else { return false }
        var result: UInt8 = 0
        for (a, b) in zip(lhs.utf8, rhs.utf8) { result |= a ^ b }
        return result == 0
    }
}

/// Routes the launch PIN: the primary PIN opens the real profile, the duress
/// PIN switches to the secret TDLib container and hides every other profile.
@MainActor
final class ProfileRouter: ObservableObject {
    static let shared = ProfileRouter()

    enum Destination: Equatable {
        case primary
        case secret
        case invalid
    }

    @Published private(set) var isLocked: Bool
    @Published private(set) var isSecretSession = false
    @Published private(set) var failedAttempts = 0

    private init() {
        isLocked = PINVault.shared.isEnabled && PINVault.shared.hasPrimaryPin
    }

    func lock() {
        guard PINVault.shared.isEnabled else { return }
        isLocked = true
        isSecretSession = false
    }

    @discardableResult
    func unlock(pin: String) async -> Destination {
        let vault = PINVault.shared
        if vault.matchesDuress(pin), let secretId = vault.secretAccountId {
            isLocked = false
            isSecretSession = true
            CallDiag.log("pin router: secret profile activated")
            await AccountManager.shared.activate(id: secretId)
            return .secret
        }
        if vault.matchesPrimary(pin) {
            isLocked = false
            isSecretSession = false
            failedAttempts = 0
            CallDiag.log("pin router: primary profile activated")
            if let primaryId = AccountStore.shared.accounts.first(where: { $0.isSecret != true })?.id {
                await AccountManager.shared.activate(id: primaryId)
            }
            return .primary
        }
        failedAttempts += 1
        return .invalid
    }
}

/// Multi-profile manager: owns the list of TDLib containers and switches the
/// active one safely (clients are closed before the database path changes).
@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published private(set) var isSwitching = false
    @Published private(set) var errorMessage: String?

    var profiles: [AccountSlot] {
        let accounts = AccountStore.shared.accounts
        if ProfileRouter.shared.isSecretSession {
            // Only the secret container may be visible in this session.
            return accounts.filter { $0.isSecret == true }
        }
        return accounts
    }

    /// Switches the active TDLib container. All clients of the previous session
    /// are closed first so SQLite files are flushed and never corrupted.
    func activate(id: String) async {
        guard AccountStore.shared.accounts.contains(where: { $0.id == id }),
              AccountStore.shared.currentId != id || TelegramClient.shared.tdClient == nil else { return }
        isSwitching = true
        errorMessage = nil
        defer { isSwitching = false }

        await TelegramClient.shared.switchAccount(to: id)
        CallDiag.log("account activated: \(id)")
    }

    func setSecret(_ id: String, isSecret: Bool) {
        AccountStore.shared.setSecret(id: id, isSecret: isSecret)
        if isSecret {
            PINVault.shared.secretAccountId = id
        } else if PINVault.shared.secretAccountId == id {
            PINVault.shared.secretAccountId = nil
        }
    }
}

/// Launch gate: primary PIN or duress PIN.
struct PINRouterView: View {
    @ObservedObject private var router = ProfileRouter.shared
    @State private var pin = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text(L10n.t("Profiles.Passcode"))
                .font(.title3.bold())
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                .frame(maxWidth: 200)
                .padding()
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            if let error {
                Text(error).font(.appFootnote).foregroundColor(.red)
            }
            Button(L10n.t("Common.Open")) {
                let entered = pin
                pin = ""
                Task {
                    let destination = await router.unlock(pin: entered)
                    if destination == .invalid {
                        error = L10n.t("Profiles.Wrong")
                    } else {
                        error = nil
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pin.isEmpty)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

/// Settings screen for profiles and the duress PIN.
struct ProfilesSecurityView: View {
    @ObservedObject private var router = ProfileRouter.shared
    @ObservedObject private var manager = AccountManager.shared
    @ObservedObject private var accounts = AccountStore.shared
    @State private var primaryPin = ""
    @State private var duressPin = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section(L10n.string("Код-пароль при запуске", "Launch passcode")) {
                Toggle(L10n.string("Запрашивать PIN", "Ask for PIN"), isOn: Binding(
                    get: { PINVault.shared.isEnabled },
                    set: { value in
                        PINVault.shared.isEnabled = value
                        status = value ? "PIN включён" : "PIN выключен"
                    }
                ))
                SecureField(L10n.string("Основной PIN", "Primary PIN"), text: $primaryPin)
                    .keyboardType(.numberPad)
                Button(L10n.string("Сохранить основной PIN", "Save primary PIN")) {
                    guard primaryPin.count >= 4 else { status = "Минимум 4 цифры"; return }
                    PINVault.shared.setPrimaryPin(primaryPin)
                    primaryPin = ""
                    status = "Основной PIN сохранён"
                }
                SecureField(L10n.string("Ложный PIN (двойное дно)", "Duress PIN (double bottom)"), text: $duressPin)
                    .keyboardType(.numberPad)
                Button(L10n.string("Сохранить ложный PIN", "Save duress PIN")) {
                    guard duressPin.count >= 4 else { status = "Минимум 4 цифры"; return }
                    PINVault.shared.setDuressPin(duressPin)
                    duressPin = ""
                    status = "Ложный PIN сохранён"
                }
                if !status.isEmpty {
                    Text(status).font(.appFootnote).foregroundColor(.secondary)
                }
            }

            Section(L10n.string("Профили (контейнеры TDLib)", "Profiles (TDLib containers)")) {
                Button(L10n.t("Profiles.Add")) {
                    guard accounts.accounts.count < 10 else { status = "Максимум 10 профилей"; return }
                    let slot = accounts.addAccount()
                    status = "Создан профиль \(slot.title) — войдите в него"
                    Task { await manager.activate(id: slot.id) }
                }
                .disabled(accounts.accounts.count >= 10)
                ForEach(accounts.accounts) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(account.title)
                            Spacer()
                            if accounts.currentId == account.id {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                        Text(account.databaseDirectory)
                            .font(.appCaption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 12) {
                            Button(L10n.t("Profiles.Secret")) {
                                manager.setSecret(account.id, isSecret: true)
                                status = "Профиль скрыт за ложным PIN"
                            }
                            .font(.appCaption)
                            Button(L10n.t("Common.Open")) {
                                Task { await manager.activate(id: account.id) }
                            }
                            .font(.appCaption)
                            if accounts.accounts.count > 1 {
                                Button(L10n.string("Удалить", "Delete"), role: .destructive) {
                                    ProfileKeychain.deleteKey(for: account.id)
                                    try? FileManager.default.removeItem(atPath: account.databaseDirectory)
                                    try? FileManager.default.removeItem(atPath: account.filesDirectory)
                                    accounts.remove(id: account.id)
                                    status = L10n.string("Профиль удалён", "Profile deleted")
                                }
                                .font(.appCaption)
                            }
                        }
                    }
                }
            }

            Section {
                Text("При вводе ложного PIN приложение откроет скрытый контейнер TDLib; остальные профили не показываются, а сессии основного аккаунта останавливаются до следующего ввода основного PIN.")
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(L10n.t("Profiles.Title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
