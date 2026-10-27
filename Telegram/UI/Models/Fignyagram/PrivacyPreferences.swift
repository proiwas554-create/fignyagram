import Foundation
import Combine

@MainActor
final class PrivacyPreferences: ObservableObject {
    static let shared = PrivacyPreferences()
    private static let key = "keepDeletedMessagesLocally"
    private static let screenKey = "blockScreenshotsAndRecording"

    @Published var keepDeletedMessages: Bool {
        didSet { UserDefaults.standard.set(keepDeletedMessages, forKey: Self.key) }
    }

    /// Hides the app content from screenshots and screen recording.
    @Published var blockScreenshots: Bool {
        didSet {
            UserDefaults.standard.set(blockScreenshots, forKey: Self.screenKey)
            ScreenProtection.shared.refresh()
        }
    }

    private init() {
        keepDeletedMessages = UserDefaults.standard.bool(forKey: Self.key)
        blockScreenshots = UserDefaults.standard.bool(forKey: Self.screenKey)
    }
}
