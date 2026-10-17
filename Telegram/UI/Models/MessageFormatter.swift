import Foundation
import TDLibKit

enum MessageFormatter {

    /// Short one-line description used in the chat list.
    static func preview(_ content: MessageContent) -> String {
        if let caption = caption(of: content), !caption.text.isEmpty {
            return "\(mediaLabel(content) ?? "") \(caption.text)".trimmingCharacters(in: .whitespaces)
        }
        if case .messageText(let t) = content { return t.text.text }
        return mediaLabel(content) ?? serviceText(content) ?? "Сообщение"
    }

    /// Text or caption with its formatting entities.
    static func caption(of content: MessageContent) -> FormattedText? {
        switch content {
        case .messageText(let t): return t.text
        case .messagePhoto(let p): return p.caption
        case .messageVideo(let v): return v.caption
        case .messageDocument(let d): return d.caption
        case .messageAnimation(let a): return a.caption
        case .messageAudio(let a): return a.caption
        case .messageVoiceNote(let v): return v.caption
        default: return nil
        }
    }

    /// Label for non-text content, nil for plain text messages.
    static func mediaLabel(_ content: MessageContent) -> String? {
        switch content {
        case .messageText: return nil
        case .messagePhoto: return "📷 Фото"
        case .messageVideo: return "🎥 Видео"
        case .messageDocument(let d): return "📄 \(d.document.fileName.isEmpty ? "Документ" : d.document.fileName)"
        case .messageAnimation: return "🎞 GIF"
        case .messageAudio(let a): return "🎵 \(a.audio.title.isEmpty ? "Аудио" : a.audio.title)"
        case .messageSticker(let s): return "\(s.sticker.emoji) Стикер"
        case .messageVoiceNote: return "🎤 Голосовое сообщение"
        case .messageVideoNote: return "📹 Видеосообщение"
        case .messagePoll(let p): return "📊 \(p.poll.question.text)"
        case .messageLocation, .messageLiveLocation: return "📍 Геопозиция"
        case .messageVenue: return "📍 Место"
        case .messageContact(let c): return "👤 \([c.contact.firstName, c.contact.lastName].filter { !$0.isEmpty }.joined(separator: " "))"
        case .messageAnimatedEmoji(let e): return e.emoji
        case .messageDice(let d): return d.emoji
        case .messageCall(let c): return c.isVideo ? "📹 Видеозвонок" : "📞 Звонок"
        case .messageStory: return "Сторис"
        case .messageGame: return "🎮 Игра"
        case .messageInvoice: return "🧾 Счёт"
        case .messageExpiredPhoto: return "📷 Фото удалено"
        case .messageExpiredVideo: return "🎥 Видео удалено"
        default: return serviceText(content) == nil ? "📎 Вложение" : nil
        }
    }

    /// Text for service messages (rendered centered in a chat), nil for regular messages.
    static func serviceText(_ content: MessageContent) -> String? {
        switch content {
        case .messageBasicGroupChatCreate(let c): return "Группа «\(c.title)» создана"
        case .messageSupergroupChatCreate(let c): return "«\(c.title)» создан(а)"
        case .messageChatChangeTitle(let c): return "Новое название: «\(c.title)»"
        case .messageChatChangePhoto: return "Фото чата обновлено"
        case .messageChatDeletePhoto: return "Фото чата удалено"
        case .messageChatAddMembers: return "Новые участники"
        case .messageChatJoinByLink, .messageChatJoinByRequest: return "Вступил(а) в чат"
        case .messageChatDeleteMember: return "Участник покинул чат"
        case .messagePinMessage: return "📌 Сообщение закреплено"
        case .messageScreenshotTaken: return "Сделан скриншот"
        case .messageContactRegistered: return "Присоединился(-ась) к Telegram"
        case .messageChatUpgradeTo, .messageChatUpgradeFrom: return "Группа преобразована в супергруппу"
        case .messageChatSetMessageAutoDeleteTime: return "Изменён таймер автоудаления"
        case .messageForumTopicCreated: return "Создана тема"
        case .messageVideoChatStarted: return "Видеочат начат"
        case .messageVideoChatEnded: return "Видеочат завершён"
        case .messageCustomServiceAction(let a): return a.text
        case .messageGiftedPremium: return "🎁 Подарок: Telegram Premium"
        case .messageGift: return "🎁 Подарок"
        default: return nil
        }
    }

    /// Converts TDLib entities into an AttributedString with links and basic styles.
    static func attributed(_ text: FormattedText) -> AttributedString {
        var result = AttributedString(text.text)
        for entity in text.entities {
            let utf16 = text.text.utf16
            guard entity.offset >= 0, entity.length > 0,
                  let start16 = utf16.index(utf16.startIndex, offsetBy: entity.offset, limitedBy: utf16.endIndex),
                  let end16 = utf16.index(start16, offsetBy: entity.length, limitedBy: utf16.endIndex),
                  let start = String.Index(start16, within: text.text),
                  let end = String.Index(end16, within: text.text)
            else { continue }
            let fragment = String(text.text[start..<end])
            let lower = result.index(result.startIndex, offsetByCharacters: text.text.distance(from: text.text.startIndex, to: start))
            let upper = result.index(lower, offsetByCharacters: fragment.count)
            let range = lower..<upper
            switch entity.type {
            case .textEntityTypeUrl:
                let urlString = fragment.contains("://") ? fragment : "https://" + fragment
                if let url = URL(string: urlString) { result[range].link = url }
            case .textEntityTypeTextUrl(let t):
                if let url = URL(string: t.url) { result[range].link = url }
            case .textEntityTypeEmailAddress:
                if let url = URL(string: "mailto:" + fragment) { result[range].link = url }
            case .textEntityTypePhoneNumber:
                if let url = URL(string: "tel:" + fragment.filter { $0.isNumber || $0 == "+" }) { result[range].link = url }
            case .textEntityTypeMention:
                if let url = URL(string: "https://t.me/" + fragment.dropFirst()) { result[range].link = url }
            #if canImport(Darwin)
            case .textEntityTypeBold:
                result[range].inlinePresentationIntent = .stronglyEmphasized
            case .textEntityTypeItalic:
                result[range].inlinePresentationIntent = .emphasized
            case .textEntityTypeStrikethrough:
                result[range].inlinePresentationIntent = .strikethrough
            case .textEntityTypeCode, .textEntityTypePre, .textEntityTypePreCode:
                result[range].inlinePresentationIntent = .code
            #endif
            default:
                break
            }
        }
        return result
    }

    static func time(_ unixTime: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
        return timeFormatter.string(from: date)
    }

    /// Date for the chat list: time today, weekday this week, otherwise a short date.
    static func listDate(_ unixTime: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeFormatter.string(from: date) }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return weekdayFormatter.string(from: date)
        }
        return dateFormatter.string(from: date)
    }

    static func userStatus(_ status: UserStatus) -> String {
        switch status {
        case .userStatusOnline: return "в сети"
        case .userStatusOffline(let s): return "был(а) в сети \(listDate(s.wasOnline))"
        case .userStatusRecently: return "был(а) недавно"
        case .userStatusLastWeek: return "был(а) на этой неделе"
        case .userStatusLastMonth: return "был(а) в этом месяце"
        case .userStatusEmpty: return "был(а) давно"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yy"
        return f
    }()
}
