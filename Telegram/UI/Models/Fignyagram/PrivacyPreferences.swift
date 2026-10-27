import Foundation
import Combine

@MainActor
final class PrivacyPreferences: ObservableObject {
    static let shared = PrivacyPreferences()
    private static let key = "keepDeletedMessagesLocally"
    private static let screenKey = "blockScreenshotsAndRecording"
    private static let ghostKey = "storyGhostMode"
    private static let copyKey = "ignoreCopyProtection"

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

    /// Never mark stories as read: views stay invisible to their authors.
    @Published var storyGhostMode: Bool {
        didSet { UserDefaults.standard.set(storyGhostMode, forKey: Self.ghostKey) }
    }

    /// Allows selection/forwarding/saving in channels that forbid it.
    @Published var ignoreCopyProtection: Bool {
        didSet { UserDefaults.standard.set(ignoreCopyProtection, forKey: Self.copyKey) }
    }

    private init() {
        keepDeletedMessages = UserDefaults.standard.bool(forKey: Self.key)
        blockScreenshots = UserDefaults.standard.bool(forKey: Self.screenKey)
        storyGhostMode = UserDefaults.standard.bool(forKey: Self.ghostKey)
        ignoreCopyProtection = (UserDefaults.standard.object(forKey: Self.copyKey) as? Bool) ?? true
    }
}
