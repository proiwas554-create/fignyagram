import Foundation

/// Single, app-wide refresh trigger. Any settings change that affects the whole
/// UI (font, interface language) increments it; the root view is rebuilt from
/// scratch because it is identified by this value.
nonisolated enum GlobalUI {
    private static let key = "app_ui_refresh_trigger"

    @MainActor
    static func bump() {
        let next = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(next, forKey: key)
        CallDiag.log("global UI refresh trigger=\(next)")
    }
}
