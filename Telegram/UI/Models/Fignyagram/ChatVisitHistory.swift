import Foundation
import Combine

struct ChatVisit: Codable, Identifiable, Equatable {
    let chatId: Int64
    var lastVisited: Foundation.Date
    var visits: Int
    var id: Int64 { chatId }
}

@MainActor
final class ChatVisitHistory: ObservableObject {
    static let shared = ChatVisitHistory()
    private static let key = "chatVisitHistory"

    @Published private(set) var visits: [ChatVisit] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([ChatVisit].self, from: data) {
            visits = saved
        }
    }

    func record(chatId: Int64) {
        let now = Foundation.Date()
        if let index = visits.firstIndex(where: { $0.chatId == chatId }) {
            visits[index].lastVisited = now
            visits[index].visits += 1
            let item = visits.remove(at: index)
            visits.insert(item, at: 0)
        } else {
            visits.insert(ChatVisit(chatId: chatId, lastVisited: now, visits: 1), at: 0)
        }
        visits = Array(visits.prefix(100))
        save()
    }

    func clear() {
        visits = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(visits) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
