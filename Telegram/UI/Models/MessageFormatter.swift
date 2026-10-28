import Foundation
import TDLibKit

enum MessageFormatter {

    /// Short one-line description used in the chat list.
    static func preview(_ content: MessageContent) -> String {
        if let caption = caption(of: content), !caption.text.isEmpty {
            return "\(mediaLabel(content) ?? "") \(caption.text)".trimmingCharacters(in: .whitespaces)
        }
        if case .messageText(let t) = content { return t.text.text }
        return mediaLabel(content) ?? serviceText(content) ?? NSLocalizedString("Generated.836947131196", comment: "")
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
        case .messagePhoto: return L10n.t("AutoR.4d07dfc39a")
        case .messageVideo: return L10n.t("AutoR.20f948cf8c")
        case .messageDocument(let d): return "📄 \(d.document.fileName.isEmpty ? "Документ" : d.document.fileName)"
        case .messageAnimation: return "🎞 GIF"
        case .messageAudio(let a): return "🎵 \(a.audio.title.isEmpty ? "Аудио" : a.audio.title)"
        case .messageSticker(let s): return String(format: L10n.t("AutoR.1f430a6f5f"), String(describing: s.sticker.emoji))
        case .messageVoiceNote: return L10n.t("AutoR.4a85e9768c")
        case .messageVideoNote: return L10n.t("AutoR.57f1054b62")
        case .messagePoll(let p): return "📊 \(p.poll.question.text)"
        case .messageLocation, .messageLiveLocation: return L10n.t("AutoR.94c9d17e6d")
        case .messageVenue: return L10n.t("AutoR.1d6cbc3c72")
        case .messageContact(let c): return "👤 \([c.contact.firstName, c.contact.lastName].filter { !$0.isEmpty }.joined(separator: " "))"
        case .messageAnimatedEmoji(let e): return e.emoji
        case .messageDice(let d): return d.emoji
        case .messageCall(let c): return c.isVideo ? "📹 Видеозвонок" : "📞 Звонок"
        case .messageStory: return L10n.t("AutoR.45eb04aa3a")
        case .messageGame: return L10n.t("AutoR.bc398effad")
        case .messageInvoice: return L10n.t("AutoR.6f952fa594")
        case .messageExpiredPhoto: return L10n.t("AutoR.25766df95c")
        case .messageExpiredVideo: return L10n.t("AutoR.ea1b4a0d9c")
        default: return serviceText(content) == nil ? "📎 Вложение" : nil
        }
    }

    /// Text for service messages (rendered centered in a chat), nil for regular messages.
    static func serviceText(_ content: MessageContent) -> String? {
        switch content {
        case .messageBasicGroupChatCreate(let c): return String(format: L10n.t("AutoR.f3c04ad3f6"), String(describing: c.title))
        case .messageSupergroupChatCreate(let c): return String(format: L10n.t("AutoR.5bd621e6db"), String(describing: c.title))
        case .messageChatChangeTitle(let c): return String(format: L10n.t("AutoR.39fac21183"), String(describing: c.title))
        case .messageChatChangePhoto: return L10n.t("AutoR.d231644d88")
        case .messageChatDeletePhoto: return L10n.t("AutoR.68ad8dd977")
        case .messageChatAddMembers: return L10n.t("AutoR.868d7bd9b5")
        case .messageChatJoinByLink, .messageChatJoinByRequest: return L10n.t("AutoR.0679f0de9e")
        case .messageChatDeleteMember: return L10n.t("AutoR.fd81e90154")
        case .messagePinMessage: return L10n.t("AutoR.6995491021")
        case .messageScreenshotTaken: return L10n.t("AutoR.a4eb70da00")
        case .messageContactRegistered: return L10n.t("AutoR.21bcda1c43")
        case .messageChatUpgradeTo, .messageChatUpgradeFrom: return L10n.t("AutoR.c7deb47a74")
        case .messageChatSetMessageAutoDeleteTime: return L10n.t("AutoR.8ad0f19b75")
        case .messageForumTopicCreated: return L10n.t("AutoR.fb3e586a26")
        case .messageVideoChatStarted: return L10n.t("AutoR.728d04e311")
        case .messageVideoChatEnded: return L10n.t("AutoR.08fc7101ae")
        case .messageCustomServiceAction(let a): return a.text
        case .messageGiftedPremium: return L10n.t("AutoR.f78c1b4fb0")
        case .messageGift: return L10n.t("AutoR.54e420c360")
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

    static func actionVerb(_ action: ChatAction) -> String {
        switch action {
        case .chatActionRecordingVoiceNote: return L10n.t("AutoR.7b1df61017")
        case .chatActionUploadingVoiceNote: return L10n.t("AutoR.4b0a6d1e9e")
        case .chatActionRecordingVideoNote: return L10n.t("AutoR.08d714d525")
        case .chatActionUploadingVideoNote: return L10n.t("AutoR.fef228955e")
        case .chatActionUploadingPhoto: return L10n.t("AutoR.0a9349721d")
        case .chatActionRecordingVideo, .chatActionUploadingVideo: return L10n.t("AutoR.2b3785ed87")
        case .chatActionUploadingDocument: return L10n.t("AutoR.6022802f39")
        case .chatActionChoosingSticker: return L10n.t("AutoR.83f289d0c2")
        default: return L10n.t("AutoR.c82fe61a84")
        }
    }

    static func reactionLabel(_ type: ReactionType) -> String {
        switch type {
        case .reactionTypeEmoji(let e): return e.emoji
        case .reactionTypeCustomEmoji: return "✨"
        case .reactionTypePaid: return "⭐️"
        }
    }

    static func duration(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
        case .userStatusOnline: return L10n.t("AutoR.d9022f72ce")
        case .userStatusOffline(let s): return String(format: L10n.t("Presence.LastSeen"), listDate(s.wasOnline))
        case .userStatusRecently: return L10n.t("AutoR.1d6716d62c")
        case .userStatusLastWeek: return L10n.t("AutoR.1c2d9fdaf4")
        case .userStatusLastMonth: return L10n.t("AutoR.303e34cf96")
        case .userStatusEmpty: return L10n.t("AutoR.987adf37da")
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
