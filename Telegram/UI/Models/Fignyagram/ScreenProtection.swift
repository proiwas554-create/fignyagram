import UIKit

/// Blocks screenshots and screen recording of the app.
///
/// iOS marks a window as "secure" as soon as it hosts a secure text field, and
/// capture of that window returns black (the same trick video players use).
/// The field is invisible, non-interactive and one pixel — it does not change
/// layout or hit testing.
@MainActor
final class ScreenProtection {
    static let shared = ScreenProtection()

    private weak var field: UITextField?

    var isActive: Bool { field != nil }

    func apply() {
        guard PrivacyPreferences.shared.blockScreenshots else {
            remove()
            return
        }
        guard field == nil, let window = Self.keyWindow() else { return }
        let secure = UITextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        secure.isSecureTextEntry = true
        secure.isUserInteractionEnabled = false
        secure.alpha = 0.01
        window.addSubview(secure)
        window.sendSubviewToBack(secure)
        field = secure
        CallDiag.log("screen protection enabled")
    }

    func remove() {
        guard field != nil else { return }
        field?.removeFromSuperview()
        field = nil
        CallDiag.log("screen protection disabled")
    }

    /// Re-attaches after a scene/window change (the field lives in a window).
    func refresh() {
        if PrivacyPreferences.shared.blockScreenshots {
            if field?.window == nil { field = nil }
            apply()
        } else {
            remove()
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }
}
