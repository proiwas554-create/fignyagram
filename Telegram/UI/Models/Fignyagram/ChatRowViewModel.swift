import Combine
import Foundation

/// Per-cell view model: resolves the translated chat/channel title immediately
/// when the row appears, so the main list is localized without opening a chat.
@MainActor
final class ChatRowViewModel: ObservableObject {
    @Published private(set) var translatedTitle: String

    let chatId: Int64
    private let originalTitle: String
    private var cancellables: Set<AnyCancellable> = []

    init(chatId: Int64, title: String) {
        self.chatId = chatId
        self.originalTitle = title
        self.translatedTitle = AutoTranslationManager.shared
            .translation(forChatId: chatId, title: title) ?? title

        AutoTranslationManager.shared.$completedCount
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        AutoTranslationManager.shared.$cacheVersion
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        AutoTranslationSettings.shared.$mode
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func start() {
        refresh()
        AutoTranslationManager.shared.requestChatTitle(chatId: chatId, title: originalTitle)
    }

    private func refresh() {
        translatedTitle = AutoTranslationManager.shared
            .translation(forChatId: chatId, title: originalTitle) ?? originalTitle
    }
}
