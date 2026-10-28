import Combine
import Foundation
import NaturalLanguage
import SwiftUI
import TDLibKit
import Translation

/// Settings for inline auto-translation.
@MainActor
final class AutoTranslationSettings: ObservableObject {
    static let shared = AutoTranslationSettings()

    private enum Keys {
        static let enabled = "isAutoTranslationEnabled"
        static let language = "targetTranslationLanguage"
    }

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    @Published var targetLanguage: String {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: Keys.language) }
    }

    /// Apple's Translation framework is unavailable before iOS 18.
    var isSupported: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        targetLanguage = UserDefaults.standard.string(forKey: Keys.language) ?? "ru"
    }

    static let supportedLanguages: [(code: String, title: String)] = [
        ("ru", "Русский"), ("en", "English"), ("de", "Deutsch"),
        ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
        ("tr", "Türkçe"), ("uk", "Українська"), ("ar", "العربية"),
        ("zh", "中文"), ("ja", "日本語"), ("ko", "한국어")
    ]
}

/// Per-message translation cache: a message is translated exactly once per
/// session, so scrolling never triggers repeated work.
@MainActor
final class TranslatedMessageCache {
    static let shared = TranslatedMessageCache()
    private let cache = NSCache<NSString, NSString>()

    private init() { cache.countLimit = 600 }

    func removeAll() {
        cache.removeAllObjects()
        CallDiag.log("translation cache cleared (target language changed)")
    }

    static func key(chatId: Int64, messageId: Int64, editDate: Int32,
                    language: String, role: String) -> NSString {
        "\(chatId):\(messageId):\(editDate):\(language):\(role)" as NSString
    }

    func translation(chatId: Int64, messageId: Int64, editDate: Int32,
                     language: String, role: String) -> String? {
        cache.object(forKey: Self.key(chatId: chatId, messageId: messageId,
                                      editDate: editDate, language: language,
                                      role: role)) as String?
    }

    func store(_ text: String, chatId: Int64, messageId: Int64, editDate: Int32,
               language: String, role: String) {
        cache.setObject(text as NSString,
                        forKey: Self.key(chatId: chatId, messageId: messageId,
                                         editDate: editDate, language: language,
                                         role: role))
    }
}

/// Drives on-device translations through Apple's Translation framework.
///
/// The framework only exposes a session inside a SwiftUI view, so the manager
/// keeps a tiny invisible host view attached to the window; requests are queued
/// on the manager and drained by that view. Everything runs off the network and
/// on the device.
@MainActor
final class AutoTranslationManager: ObservableObject {
    static let shared = AutoTranslationManager()

    struct Request: Identifiable, Equatable {
        let id: String          // chatId:messageId:editDate
        let chatId: Int64
        let messageId: Int64
        let editDate: Int32
        let text: String
        let role: String
    }

    @Published private(set) var pending: [Request] = []
    /// Bumped whenever a translation lands, so cells re-read the cache.
    @Published private(set) var completedCount = 0
    @Published private(set) var isUnavailable = false

    private var inFlight: Set<String> = []
    private var host: UIViewController?

    private var cancellables: Set<AnyCancellable> = []
    /// Bumped when the target language changes so every visible cell re-requests.
    @Published private(set) var cacheVersion = 0

    private init() {
        AutoTranslationSettings.shared.$targetLanguage
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.handleTargetLanguageChange()
            }
            .store(in: &cancellables)
    }

    private func handleTargetLanguageChange() {
        TranslatedMessageCache.shared.removeAll()
        inFlight.removeAll()
        pending.removeAll()
        cacheVersion += 1
        CallDiag.log("auto translation target changed to \(AutoTranslationSettings.shared.targetLanguage)")
    }

    func translation(for message: TDLibKit.Message, text: String, role: String = "body") -> String? {
        guard AutoTranslationSettings.shared.isEnabled else { return nil }
        return TranslatedMessageCache.shared.translation(chatId: message.chatId,
                                                         messageId: message.id,
                                                         editDate: Int32(message.editDate),
                                                         language: AutoTranslationSettings.shared.targetLanguage,
                                                         role: role)
    }

    /// Manual translation from the message menu: works even when auto mode is
    /// off, still using the selected target language and the same cache.
    @discardableResult
    func requestManual(message: TDLibKit.Message, text: String, role: String = "body") -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        let settings = AutoTranslationSettings.shared
        let key = "\(message.chatId):\(message.id):\(message.editDate):\(role)"
        guard TranslatedMessageCache.shared.translation(chatId: message.chatId,
                                                        messageId: message.id,
                                                        editDate: Int32(message.editDate),
                                                        language: settings.targetLanguage,
                                                        role: role) == nil else { return true }
        guard !inFlight.contains(key) else { return true }
        inFlight.insert(key)
        pending.append(Request(id: key, chatId: message.chatId, messageId: message.id,
                               editDate: Int32(message.editDate), text: trimmed, role: role))
        attachHostIfNeeded()
        CallDiag.log("manual translation queued: message=\(message.id) target=\(settings.targetLanguage)")
        return true
    }

    func requestIfNeeded(message: TDLibKit.Message, text: String, role: String = "body") {
        let settings = AutoTranslationSettings.shared
        guard settings.isEnabled, settings.isSupported else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        // Skip text that is already in the target language.
        guard Self.language(of: trimmed) != settings.targetLanguage else { return }

        let key = "\(message.chatId):\(message.id):\(message.editDate):\(role)"
        guard !inFlight.contains(key),
              TranslatedMessageCache.shared.translation(chatId: message.chatId,
                                                        messageId: message.id,
                                                        editDate: Int32(message.editDate),
                                                        language: settings.targetLanguage,
                                                        role: role) == nil else { return }
        inFlight.insert(key)
        pending.append(Request(id: key, chatId: message.chatId, messageId: message.id,
                               editDate: Int32(message.editDate), text: trimmed, role: role))
        CallDiag.log("auto translation queued: message=\(message.id) target=\(settings.targetLanguage) role=\(role)")
        attachHostIfNeeded()
    }

    func finish(_ request: Request, translation: String?) {
        inFlight.remove(request.id)
        pending.removeAll { $0.id == request.id }
        if let translation, !translation.isEmpty {
            let language = AutoTranslationSettings.shared.targetLanguage
            TranslatedMessageCache.shared.store(translation,
                                                chatId: request.chatId,
                                                messageId: request.messageId,
                                                editDate: request.editDate,
                                                language: language,
                                                role: request.role)
            completedCount += 1
        }
    }

    func markUnavailable() {
        guard !isUnavailable else { return }
        isUnavailable = true
        if #available(iOS 18.0, *) {} else {
            AutoTranslationSettings.shared.isEnabled = false
        }
        CallDiag.log("auto translation unavailable on this device")
    }

    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    private func attachHostIfNeeded() {
        guard host == nil else { return }
        guard #available(iOS 18.0, *) else {
            markUnavailable()
            return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return }
        let controller = UIHostingController(rootView: TranslationHostView(manager: self))
        controller.view.backgroundColor = .clear
        controller.view.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        controller.view.alpha = 0.01
        controller.view.isUserInteractionEnabled = false
        window.addSubview(controller.view)
        host = controller
    }
}

/// Invisible host that owns the Apple Translation session.
@available(iOS 18.0, *)
struct TranslationHostView: View {
    @ObservedObject var manager: AutoTranslationManager
    @ObservedObject private var settings = AutoTranslationSettings.shared
    @State private var configuration: TranslationSession.Configuration? = nil

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .onAppear {
                configuration = TranslationSession.Configuration(
                    source: nil,
                    target: Locale.Language(identifier: settings.targetLanguage)
                )
            }
            .onChange(of: manager.pending.count) { _ in
                configuration?.invalidate()
            }
            .onChange(of: settings.targetLanguage) { value in
                configuration = TranslationSession.Configuration(
                    source: nil,
                    target: Locale.Language(identifier: value)
                )
            }
            .translationTask(configuration) { session in
                await drain(session)
            }
    }

    private func drain(_ session: TranslationSession) async {
        while let request = manager.pending.first {
            do {
                let response = try await session.translate(request.text)
                manager.finish(request, translation: response.targetText)
            } catch {
                manager.finish(request, translation: nil)
            }
        }
    }
}

/// Message body that swaps in the on-device translation when available.
struct AutoTranslatedMessageText: View {
    let message: TDLibKit.Message
    let formatted: TDLibKit.FormattedText
    var role: String = "body"

    @ObservedObject private var settings = AutoTranslationSettings.shared
    @ObservedObject private var manager = AutoTranslationManager.shared
    @State private var translated: String?

    var body: some View {
        Group {
            if let translated {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(translated)
                        .modifier(SelectableTextModifier())
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .accessibilityLabel(L10n.keyed("Chat.Globe", ru: "Переведено", en: "Translated"))
                }
            } else {
                SpoilerTextView(formatted: formatted)
            }
        }
        .onAppear {
            request()
        }
        .onChange(of: settings.isEnabled) { _ in
            translated = manager.translation(for: message, text: formatted.text, role: role)
            request()
        }
        .onChange(of: settings.targetLanguage) { _ in
            translated = nil
            request()
        }
        .onChange(of: manager.completedCount) { _ in
            translated = manager.translation(for: message, text: formatted.text, role: role)
        }
        .onChange(of: manager.cacheVersion) { _ in
            translated = manager.translation(for: message, text: formatted.text, role: role)
            request()
        }
    }

    private func request() {
        guard settings.isEnabled else {
            translated = nil
            return
        }
        if let cached = manager.translation(for: message, text: formatted.text, role: role) {
            translated = cached
            return
        }
        manager.requestIfNeeded(message: message, text: formatted.text, role: role)
    }
}
