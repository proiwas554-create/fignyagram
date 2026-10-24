import SwiftUI
import TDLibKit
import Combine

/// Plain-Old-Data view model for a chat list row. Contains everything the row
/// needs to render, so `ChatRow.body` performs no store lookups, no date
/// formatting and no preview parsing — those happen once, outside the scroll
/// hot path.
struct ChatRowPresentation: Equatable {
    let chatId: Int64
    let title: String
    let previewText: String
    let dateText: String
    let actionText: String?
    let senderName: String
    let isPinned: Bool
    let hidesLastMessage: Bool
    let isRecent: Bool
    let isSaved: Bool
    let isLastOpened: Bool
    let isChannel: Bool
    let isGroup: Bool
    let unreadCount: Int
    let isMarkedAsUnread: Bool
    let checkmarkCount: Int          // 0 = none, 1 = sent, 2 = read
    let avatarImage: UIImage?

    static func == (lhs: ChatRowPresentation, rhs: ChatRowPresentation) -> Bool {
        lhs.chatId == rhs.chatId
            && lhs.title == rhs.title
            && lhs.previewText == rhs.previewText
            && lhs.dateText == rhs.dateText
            && lhs.actionText == rhs.actionText
            && lhs.senderName == rhs.senderName
            && lhs.isPinned == rhs.isPinned
            && lhs.hidesLastMessage == rhs.hidesLastMessage
            && lhs.isRecent == rhs.isRecent
            && lhs.isSaved == rhs.isSaved
            && lhs.isLastOpened == rhs.isLastOpened
            && lhs.isChannel == rhs.isChannel
            && lhs.isGroup == rhs.isGroup
            && lhs.unreadCount == rhs.unreadCount
            && lhs.isMarkedAsUnread == rhs.isMarkedAsUnread
            && lhs.checkmarkCount == rhs.checkmarkCount
            && lhs.avatarImage === rhs.avatarImage
    }
}

/// Decodes chat avatars once on a background queue and publishes the finished
/// UIImage. Rows never subscribe to FileStore: they read a ready image from
/// this cache, so a file-progress update no longer re-renders the whole list.
@MainActor
final class ChatListAvatarCache: ObservableObject {
    static let shared = ChatListAvatarCache()

    @Published private(set) var images: [Int64: UIImage] = [:]
    @ObservedObject private var files = FileStore.shared
    private var requested: Set<Int64> = []
    private var pending: [Int64: TDLibKit.File] = [:]
    private var subscriptions: Set<AnyCancellable> = []

    private init() {
        // ONE subscription for the whole list instead of one per row.
        files.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.drainPending() }
            .store(in: &subscriptions)
    }

    func image(for chatId: Int64) -> UIImage? { images[chatId] }

    /// Called from `.onAppear` of a visible row.
    func warm(chatId: Int64, photo: TDLibKit.ChatPhotoInfo?) {
        guard !requested.contains(chatId), let photo else { return }
        requested.insert(chatId)

        if let path = files.localPath(photo.small) {
            decode(chatId, path: path)
        } else {
            pending[chatId] = photo.small
            TelegramClient.shared.download(photo.small, priority: 1)
        }
    }

    /// FileStore published → check queued avatars and decode the ready ones.
    private func drainPending() {
        for (chatId, file) in pending {
            if let path = files.localPath(file) {
                pending.removeValue(forKey: chatId)
                decode(chatId, path: path)
            }
        }
    }

    private func decode(_ chatId: Int64, path: String) {
        DiagnosticsLog.log("avatar.decode start chat=\(chatId)")
        Task.detached(priority: .utility) { [weak self] in
            let decoded = await ImageCache.imageAsync(atPath: path, maxPixel: 160)
            guard let self, let decoded else { return }
            await MainActor.run {
                self.images[chatId] = decoded
            }
        }
    }
}
