import Foundation
import Combine

@MainActor
final class SearchHistory: ObservableObject {
    static let shared = SearchHistory()
    private static let key = "searchHistory"
    private let limit = 25

    @Published private(set) var items: [String] = []

    private init() {
        items = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func record(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return }
        items.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
        items.insert(value, at: 0)
        items = Array(items.prefix(limit))
        UserDefaults.standard.set(items, forKey: Self.key)
    }

    func remove(_ query: String) {
        items.removeAll { $0 == query }
        UserDefaults.standard.set(items, forKey: Self.key)
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
