import Foundation
import TDLibKit

/// Persistent archive of permanently deleted messages. TDLib stops returning
/// these messages, so keeping them only in memory lost them after restart.
/// Messages are archived ALWAYS (so toggling the preference later still shows
/// history) and displayed only when the preference is enabled.
@MainActor
final class DeletedMessageStore {
    static let shared = DeletedMessageStore()

    private var archived: [Int64: [Message]] = [:]
    private let url: URL
    private let limitPerChat = 300

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("deleted_messages.json")
        load()
    }

    func messages(chatId: Int64) -> [Message] {
        archived[chatId] ?? []
    }

    func archive(chatId: Int64, messages newMessages: [Message]) {
        guard !newMessages.isEmpty else { return }
        var list = archived[chatId] ?? []
        for message in newMessages where !list.contains(where: { $0.id == message.id }) {
            list.append(message)
        }
        list.sort { $0.id < $1.id }
        if list.count > limitPerChat {
            list.removeFirst(list.count - limitPerChat)
        }
        archived[chatId] = list
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Int64: [Message]].self, from: data) else { return }
        archived = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(archived) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
