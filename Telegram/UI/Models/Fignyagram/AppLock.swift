import Foundation
import Combine
import LocalAuthentication

/// Optional Face ID / Touch ID lock. The code never leaves the device: only
/// LocalAuthentication is used, no biometric data is stored by the app.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "appLockEnabled") }
    }
    @Published private(set) var isLocked = false
    @Published private(set) var lastError: String?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "appLockEnabled")
        isLocked = isEnabled
    }

    func lockIfNeeded() {
        guard isEnabled else { return }
        isLocked = true
    }

    func unlock() async {
        guard isEnabled, isLocked else { return }

        let context = LAContext()
        context.localizedFallbackTitle = "Ввести пароль"

        // Face ID / Touch ID first: the passcode sheet is only a fallback.
        var biometricsError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricsError) {
            do {
                let ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Разблокируйте Fignyagram"
                )
                if ok { isLocked = false; lastError = nil }
                return
            } catch {
                lastError = error.localizedDescription
                // If the user cancelled explicitly, do not silently ask for the passcode.
                if (error as NSError).code == LAError.userCancel.rawValue { return }
            }
        }

        let fallback = LAContext()
        var fallbackError: NSError?
        guard fallback.canEvaluatePolicy(.deviceOwnerAuthentication, error: &fallbackError) else {
            lastError = biometricsError?.localizedDescription ?? fallbackError?.localizedDescription
            return
        }
        do {
            let ok = try await fallback.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Разблокируйте Fignyagram"
            )
            if ok { isLocked = false; lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
