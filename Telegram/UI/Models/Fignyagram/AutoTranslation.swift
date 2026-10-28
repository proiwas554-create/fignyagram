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

    enum Mode: String, CaseIterable, Identifiable {
        case auto, manual, disabled
        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: return L10n.t("Translation.Mode.Auto")
            case .manual: return L10n.t("Translation.Mode.Manual")
            case .disabled: return L10n.t("Translation.Mode.Disabled")
            }
        }
    }

    private enum Keys {
        static let enabled = "isAutoTranslationEnabled"
        static let language = "targetTranslationLanguage"
        static let mode = "translationMode"
    }

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            UserDefaults.standard.set(mode == .auto, forKey: Keys.enabled)
            if mode == .disabled {
                TranslatedMessageCache.shared.removeAll()
                AutoTranslationManager.shared.purgePending()
            }
        }
    }

    /// Kept for the existing call sites: true only in full auto mode.
    var isEnabled: Bool { mode == .auto }

    @Published var targetLanguage: String {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: Keys.language) }
    }

    /// Apple's Translation framework is unavailable before iOS 18.
    var isSupported: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Keys.mode),
           let stored = Mode(rawValue: raw) {
            mode = stored
        } else {
            mode = UserDefaults.standard.bool(forKey: Keys.enabled) ? .auto : .manual
        }
        targetLanguage = UserDefaults.standard.string(forKey: Keys.language) ?? "ru"
    }

    func setTargetLanguage(_ value: String) {
        targetLanguage = value
        UserDefaults.standard.set(value, forKey: Keys.language)
        AutoTranslationManager.shared.resetPackCache()
    }

    func reloadFromDefaults() {
        if let raw = UserDefaults.standard.string(forKey: Keys.mode),
           let stored = Mode(rawValue: raw) {
            mode = stored
        }
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
    /// Bumped only when new work is queued, so the host can restart its session
    /// without invalidating on every layout pass (that caused the download loop).
    @Published private(set) var requestGeneration = 0
    var isDraining = false
    var pendingPreparation = false
    private var preparedLanguages: Set<String> = []
    private var packStatus: [String: Bool] = [:]
    private var packCheckedAt: [String: Foundation.Date] = [:]
    private var packChecks: Set<String> = []

    private init() {
        AutoTranslationSettings.shared.$targetLanguage
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.handleTargetLanguageChange()
            }
            .store(in: &cancellables)
    }

    /// Chats never start a translation session for a missing language pack:
    /// the host is attached only after `isPackInstalled` returned true, so
    /// Apple's download sheet cannot be triggered by scrolling or opening chats.
    /// Queues the request, but only when the language pack is already installed.
    /// The session is therefore never started for a missing pack from a chat.
    private func enqueue(request: Request, target: String) {
        if let installed = packStatus[target] {
            if installed { commit(request); return }
            let last = packCheckedAt[target]
            if let last, Foundation.Date().timeIntervalSince(last) < 45 { return }
        }
        guard !packChecks.contains(target) else { return }
        packChecks.insert(target)
        // Detection + availability checks run fully off the main thread so chat
        // and list scrolling is never blocked by the translation pipeline.
        Task.detached(priority: .userInitiated) {
            let installed = await Self.isPackInstalled(text: request.text, target: target)
            await MainActor.run {
                self.packStatus[target] = installed
                self.packCheckedAt[target] = Foundation.Date()
                self.packChecks.remove(target)
                if installed {
                    self.commit(request)
                } else {
                    CallDiag.log("translation pack not installed for \(target): keeping original text")
                }
            }
        }
    }

    private func commit(_ request: Request) {
        guard !inFlight.contains(request.id) else { return }
        inFlight.insert(request.id)
        pending.append(request)
        requestGeneration += 1
        attachHostIfNeeded()
    }

    /// Hard guard: the exact source→target pair must be installed on device.
    /// Anything else silently keeps the original TDLib text and never starts a
    /// translation session (that is what triggered Apple's download sheet).
    nonisolated static func isPackInstalled(text: String, target: String) async -> Bool {
        if #available(iOS 18.0, *) {
            let source = Locale.Language(identifier: language(of: text) ?? "en")
            let destination = Locale.Language(identifier: target)
            let status = await LanguageAvailability().status(from: source, to: destination)
            return status == LanguageAvailability.Status.installed
        }
        return false
    }

    /// Chat/channel titles use the same cache with role "title".
    func translation(forChatId chatId: Int64, title: String) -> String? {
        guard AutoTranslationSettings.shared.mode != .disabled else { return nil }
        return TranslatedMessageCache.shared.translation(chatId: chatId,
                                                         messageId: 0,
                                                         editDate: 0,
                                                         language: AutoTranslationSettings.shared.targetLanguage,
                                                         role: "title")
    }

    func requestChatTitle(chatId: Int64, title: String) {
        let settings = AutoTranslationSettings.shared
        guard settings.mode == .auto, settings.isSupported else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        guard Self.language(of: trimmed) != settings.targetLanguage else { return }
        let key = "\(chatId):0:0:title"
        guard !inFlight.contains(key),
              TranslatedMessageCache.shared.translation(chatId: chatId, messageId: 0,
                                                        editDate: 0,
                                                        language: settings.targetLanguage,
                                                        role: "title") == nil else { return }
        enqueue(request: Request(id: key, chatId: chatId, messageId: 0,
                                 editDate: 0, text: trimmed, role: "title"),
                target: settings.targetLanguage)
    }

    /// Called once when the user picks a language: the system may need to
    /// download the language pack, and that must happen only here.
    func requestLanguagePreparation() {
        guard AutoTranslationSettings.shared.isSupported else { return }
        // Settings screen only: attaches the session so the user can download
        // the pack through Apple's own sheet. Chats never call this.
        let target = AutoTranslationSettings.shared.targetLanguage
        packStatus.removeValue(forKey: target)
        packCheckedAt.removeValue(forKey: target)
        packChecks.remove(target)
        pendingPreparation = true
        requestGeneration += 1
        attachHostIfNeeded()
    }

    /// Silent translation entry point for cells: returns a cached translation,
    /// queues a background one and otherwise yields the original text.
    func translate(_ text: String, role: String = "body", message: TDLibKit.Message?) async -> String {
        guard AutoTranslationSettings.shared.mode == .auto else { return text }
        if let message, let cached = translation(for: message, text: text, role: role) {
            return cached
        }
        if let message { requestIfNeeded(message: message, text: text, role: role) }
        return text
    }

    func resetPackCache() {
        packStatus.removeAll()
        packCheckedAt.removeAll()
        packChecks.removeAll()
        CallDiag.log("translation pack cache reset")
    }

    func purgePending() {
        pending.removeAll()
        inFlight.removeAll()
        cacheVersion += 1
    }

    private func handleTargetLanguageChange() {
        TranslatedMessageCache.shared.removeAll()
        inFlight.removeAll()
        pending.removeAll()
        cacheVersion += 1
        CallDiag.log("auto translation target changed to \(AutoTranslationSettings.shared.targetLanguage)")
    }

    func translation(for message: TDLibKit.Message, text: String, role: String = "body") -> String? {
        guard AutoTranslationSettings.shared.mode != .disabled else { return nil }
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
        guard AutoTranslationSettings.shared.mode != .disabled else { return false }
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
        requestGeneration += 1
        attachHostIfNeeded()
        CallDiag.log("manual translation queued: message=\(message.id) target=\(settings.targetLanguage)")
        return true
    }

    func requestIfNeeded(message: TDLibKit.Message, text: String, role: String = "body") {
        let settings = AutoTranslationSettings.shared
        guard settings.mode == .auto, settings.isSupported else { return }
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
        enqueue(request: Request(id: key, chatId: message.chatId, messageId: message.id,
                                 editDate: Int32(message.editDate), text: trimmed, role: role),
                target: settings.targetLanguage)
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
            AutoTranslationSettings.shared.mode = .disabled
        }
        CallDiag.log("auto translation unavailable on this device")
    }

    nonisolated static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Prefetch used by cells: detection and availability checks run in a
    /// detached task so scrolling never waits on NaturalLanguage or Apple's
    /// availability service.
    nonisolated static func backgroundPrefetch(text: String, target: String) async -> Bool {
        guard let source = language(of: text) else { return false }
        if #available(iOS 18.0, *) {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: source),
                to: Locale.Language(identifier: target)
            )
            return status == LanguageAvailability.Status.installed
        }
        return false
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
        guard !manager.isDraining else { return }
        manager.isDraining = true
        defer { manager.isDraining = false }

        if manager.pendingPreparation {
            manager.pendingPreparation = false
            // Only the settings screen sets this flag; chats never do.
            try? await session.prepareTranslation()
        }
        // Long-lived loop: the session is created exactly once per language and
        // is never invalidated from chat rendering, so Apple's download sheet
        // cannot be triggered from lists or message cells.
        while !Task.isCancelled {
            guard let request = manager.pending.first else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            // Never let Apple show its download sheet from a chat: translate
            // only when the language pack is already installed.
            if #available(iOS 18.0, *) {
                let target = Locale.Language(identifier: AutoTranslationSettings.shared.targetLanguage)
                var installed = false
                if let code = AutoTranslationManager.language(of: request.text) {
                    let source = Locale.Language(identifier: code)
                    let status: LanguageAvailability.Status =
                        await LanguageAvailability().status(from: source, to: target)
                    installed = (status == LanguageAvailability.Status.installed)
                }
                guard installed else {
                    // Missing pack: silently keep the original text. The sheet is
                    // only ever shown from Settings via prepareTranslation().
                    manager.finish(request, translation: nil)
                    continue
                }
            }
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
