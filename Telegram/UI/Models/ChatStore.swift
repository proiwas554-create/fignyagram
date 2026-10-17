import Foundation
import Combine
import TDLibKit

@MainActor
final class ChatStore: ObservableObject {

    static let shared = ChatStore()
    private init() {}

    /// chatId → название чата
    @Published var chats: [Int64: String] = [:]

    /// chatId → массив текстов сообщений
    @Published var messages: [Int64: [String]] = [:]
    
    /// ID чатов, которые прямо сейчас загружаются
    @Published var loadingChats: Set<Int64> = []
    
    /// ID чатов, которые мы УЖЕ успешно загрузили (чтобы не грузить повторно)
    @Published var loadedChats: Set<Int64> = []

    func addChat(_ chat: Chat) {
        chats[chat.id] = chat.title
    }

    func addMessage(chatId: Int64, text: String) {
        messages[chatId, default: []].append(text)
    }
    
    func setHistory(chatId: Int64, messages: [String]) {
        self.messages[chatId] = messages
        self.loadedChats.insert(chatId) // Помечаем, что история загружена
    }
    
    func startLoading(chatId: Int64) {
        loadingChats.insert(chatId)
    }
    
    func finishLoading(chatId: Int64) {
        loadingChats.remove(chatId)
    }
}
