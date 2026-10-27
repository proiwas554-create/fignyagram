import Foundation
import Combine

/// Recently opened private chats, shown as quick contacts above the chat list.
@MainActor
final class RecentContactsStore: ObservableObject {
    static let shared = RecentContactsStore()
    private static let key = "recentContactIds"

    @Published private(set) var userIds: [Int64] = []

    private init() {
        userIds = (UserDefaults.standard.array(forKey: Self.key) as? [NSNumber])?.map { $0.int64Value } ?? []
    }

    func record(_ userId: Int64) {
        guard userId != 0 else { return }
        userIds.removeAll { $0 == userId }
        userIds.insert(userId, at: 0)
        if userIds.count > 8 { userIds = Array(userIds.prefix(8)) }
        UserDefaults.standard.set(userIds.map { NSNumber(value: $0) }, forKey: Self.key)
    }

    func remove(_ userId: Int64) {
        userIds.removeAll { $0 == userId }
        UserDefaults.standard.set(userIds.map { NSNumber(value: $0) }, forKey: Self.key)
    }

    func clear() {
        userIds = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
