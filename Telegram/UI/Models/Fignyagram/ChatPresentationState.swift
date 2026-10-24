import Foundation
import Combine

/// Tracks whether a chat is currently presented above the tab bar, so overlays
/// that belong to the tab bar cannot intercept taps inside a chat.
@MainActor
final class ChatPresentationState: ObservableObject {
    static let shared = ChatPresentationState()
    @Published private(set) var openCount = 0

    private init() {}

    var isChatOpen: Bool { openCount > 0 }

    func enter() { openCount += 1 }
    func leave() { openCount = max(0, openCount - 1) }

    func reset() { openCount = 0 }
}
