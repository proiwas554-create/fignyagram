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

    private var requestTask: Task<Void, Never>?

    func start() {
        refresh()
        guard AutoTranslationManager.shared.translation(forChatId: chatId, title: originalTitle) == nil,
              AutoTranslationManager.shared.titlePrefetchEnabled else { return }
        // Debounce: while the list is scrolling fast, cells appear and vanish
        // immediately; only cells that stay on screen get translated.
        requestTask?.cancel()
        requestTask = Task.detached(priority: .background) { [chatId, originalTitle] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await AutoTranslationManager.shared.requestChatTitle(chatId: chatId, title: originalTitle)
        }
    }

    func stop() {
        requestTask?.cancel()
        requestTask = nil
    }

    private func refresh() {
        translatedTitle = AutoTranslationManager.shared
            .translation(forChatId: chatId, title: originalTitle) ?? originalTitle
    }
}
