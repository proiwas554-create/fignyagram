import Foundation
import Combine
import TDLibKit
import UIKit

@MainActor
final class TelegramClient: ObservableObject {

    static let shared = TelegramClient()
    private init() {}

    private var manager: TDLibClientManager?
    private var client: TDLibClient?

    @Published var isAuthorized = false
    @Published var authState: String = "Инициализация..."

    func start() {
        guard manager == nil else { return }

        manager = TDLibClientManager()

        client = manager?.createClient { [weak self] data, client in
            guard let self else { return }
            do {
                let update = try client.decoder.decode(Update.self, from: data)
                Task { @MainActor in
                    self.handle(update)
                }
            } catch {
                print("❌ Decode error: \(error)")
            }
        }

        setTdlibParameters()
    }

    private func setTdlibParameters() {
        guard let client else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path

        Task {
            // Отключаем спам логами TDLib
            _ = try? await client.execute(query: SetLogVerbosityLevel(newVerbosityLevel: 1) as! TdQuery)
            
            do {
                try await client.setTdlibParameters(
                    apiHash: Secrets.apiHash, apiId: Secrets.apiId,
                    applicationVersion: "Fignyagram 0.1.0",
                    databaseDirectory: docs + "/tdlib_db", databaseEncryptionKey: nil,
                    deviceModel: "iPhone", filesDirectory: docs + "/tdlib_files",
                    systemLanguageCode: "ru", systemVersion: UIDevice.current.systemVersion,
                    useChatInfoDatabase: true, useFileDatabase: true,
                    useMessageDatabase: true, useSecretChats: false, useTestDc: false
                )
            } catch { print("❌ Ошибка SetTdlibParameters: \(error)") }
        }
    }

    private func handle(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let wrapper):
            handleAuthState(wrapper.authorizationState)
        case .updateNewMessage(let wrapper):
            let text = getMessageText(wrapper.message)
            ChatStore.shared.addMessage(chatId: wrapper.message.chatId, text: text)
        case .updateNewChat(let wrapper):
            ChatStore.shared.addChat(wrapper.chat)
        default:
            break
        }
    }

    private func handleAuthState(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters: authState = "Инициализация..."
        case .authorizationStateWaitPhoneNumber: authState = "Введите номер телефона"
        case .authorizationStateWaitCode: authState = "Введите код из Telegram"
        case .authorizationStateWaitPassword: authState = "Введите пароль 2FA"
        case .authorizationStateReady:
            authState = "Готово"; isAuthorized = true; loadChats()
        case .authorizationStateClosed: authState = "Сессия закрыта"
        default: authState = "Состояние: \(state)"
        }
    }

    func sendPhoneNumber(_ phone: String) {
        guard let client else { return }
        Task {
            do {
                try await client.setAuthenticationPhoneNumber(
                    phoneNumber: phone,
                    settings: PhoneNumberAuthenticationSettings(
                        allowFlashCall: false, allowMissedCall: false, allowSmsRetrieverApi: false,
                        authenticationTokens: [], firebaseAuthenticationSettings: nil,
                        hasUnknownPhoneNumber: false, isCurrentPhoneNumber: false
                    )
                )
            } catch { print("❌ Ошибка номера: \(error)") }
        }
    }

    func sendCode(_ code: String) {
        guard let client else { return }
        Task { do { try await client.checkAuthenticationCode(code: code) } catch { print("❌ Ошибка кода: \(error)") } }
    }

    func sendPassword(_ password: String) {
        guard let client else { return }
        Task { do { try await client.checkAuthenticationPassword(password: password) } catch { print("❌ Ошибка пароля: \(error)") } }
    }

    func loadChats() {
        guard let client else { return }
        Task { do { try await client.loadChats(chatList: .chatListMain, limit: 50) } catch { print("❌ Ошибка loadChats: \(error)") } }
    }

    func loadHistory(chatId: Int64, forceReload: Bool = false) {
        guard let client = self.client else { return }
        
        if !forceReload && ChatStore.shared.loadedChats.contains(chatId) { return }
        if ChatStore.shared.loadingChats.contains(chatId) { return }
        
        ChatStore.shared.startLoading(chatId: chatId)
        
        Task {
            defer {
                Task { @MainActor in
                    ChatStore.shared.finishLoading(chatId: chatId)
                }
            }
            
            do {
                print("1️⃣ Запрашиваем инфу о чате \(chatId)...")
                let chat = try await client.getChat(chatId: chatId)
                print("2️⃣ Инфа получена. Тип: \(chat.type)")
                
                // Если это канал/супергруппа, принудительно вступаем (иначе истории не будет)
                if case .chatTypeSupergroup = chat.type {
                    print("3️⃣ Это супергруппа/канал. Пробуем подписаться...")
                    _ = try? await client.joinChat(chatId: chatId)
                }
                
                print("4️⃣ Вызываем openChat...")
                try await client.openChat(chatId: chatId)
                print("5️⃣ openChat завершен успешно!")
                
                print("6️⃣ Запрашиваем историю...")
                let history = try await client.getChatHistory(
                    chatId: chatId, fromMessageId: 0, limit: 50, offset: 0, onlyLocal: false
                )
                print("7️⃣ История получена! Сообщений: \(history.messages!.count)")
                
                let reversedMessages = history.messages!.reversed()
                var texts: [String] = []
                for message in reversedMessages {
                    texts.append(getMessageText(message))
                }
                
                await MainActor.run {
                    ChatStore.shared.setHistory(chatId: chatId, messages: texts)
                    print("8️⃣ Сохранено в ChatStore")
                }
                
            } catch {
                print("❌ Ошибка на одном из шагов: \(error)")
            }
        }
    }

    private func getMessageText(_ message: Message) -> String {
        switch message.content {
        case .messageText(let t): return t.text.text
        case .messagePhoto(let p): return p.caption.text.isEmpty ? "📷 [Фото]" : "📷 \(p.caption.text)"
        case .messageVideo(let v): return v.caption.text.isEmpty ? "🎥 [Видео]" : "🎥 \(v.caption.text)"
        case .messageDocument(let d): return d.caption.text.isEmpty ? "📄 [Документ]" : "📄 \(d.caption.text)"
        case .messageAnimation(let a): return a.caption.text.isEmpty ? "🎞 [GIF]" : "🎞 \(a.caption.text)"
        case .messageAudio(let a): return a.caption.text.isEmpty ? "🎵 [Аудио]" : "🎵 \(a.caption.text)"
        case .messageSticker(let s): return "🩹 Стикер \(s.sticker.emoji)"
        case .messageVoiceNote: return "🎤 Голосовое сообщение"
        case .messageVideoNote: return "📹 Кружок"
        case .messagePoll(let p): return "📊 Опрос: \(p.poll.question)"
        case .messageLocation: return "📍 Геопозиция"
        case .messageContact(let c): return "👤 Контакт: \(c.contact.firstName)"
        case .messagePinMessage: return "📌 Закреплено"
        case .messageChatChangeTitle(let t): return "⚙️ Название: \(t.title)"
        default: return "📎 Вложение"
        }
    }

    func sendMessage(chatId: Int64, text: String) {
        guard let client else { return }
        Task {
            do {
                try await client.sendMessage(
                    chatId: chatId,
                    inputMessageContent: .inputMessageText(
                        InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: FormattedText(entities: [], text: text))
                    ),
                    options: nil, replyMarkup: nil, replyTo: nil, topicId: nil
                )
            } catch { print("❌ Ошибка sendMessage: \(error)") }
        }
    }

    func close() { manager?.closeClients() }
}
