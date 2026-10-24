import Foundation
import Combine

@MainActor
final class PrivacyPreferences: ObservableObject {
    static let shared = PrivacyPreferences()
    private static let key = "keepDeletedMessagesLocally"

    @Published var keepDeletedMessages: Bool {
        didSet { UserDefaults.standard.set(keepDeletedMessages, forKey: Self.key) }
    }

    private init() {
        keepDeletedMessages = UserDefaults.standard.bool(forKey: Self.key)
    }
}
