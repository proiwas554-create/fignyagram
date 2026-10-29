import Foundation

struct WatchMessage: Identifiable, Codable, Equatable, Hashable {
    let id: Int64
    let text: String
    let senderName: String
    let isOutgoing: Bool
    let timestamp: Int
}
