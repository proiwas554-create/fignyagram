import Foundation

/// Lightweight payload exchanged over WatchConnectivity: no TDLib types.
struct WatchChat: Identifiable, Codable, Equatable, Hashable {
    let id: Int64
    let title: String
    let preview: String
    let unread: Int
    let isPinned: Bool
    let isMuted: Bool
}
