import Foundation
import SwiftUI
import Combine

@MainActor
final class TranslationService: ObservableObject {
    static let shared = TranslationService()
    private static let enabledKey = "uiTranslationEnabled"
    private static let onboardedKey = "uiTranslationOnboarded"
    private static let autoMessagesKey = "autoTranslateMessages"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    @Published var autoTranslateMessages: Bool {
        didSet { UserDefaults.standard.set(autoTranslateMessages, forKey: Self.autoMessagesKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        let english = Locale.preferredLanguages.first?.lowercased().hasPrefix("en") ?? false
        if !defaults.bool(forKey: Self.onboardedKey) {
            defaults.set(true, forKey: Self.onboardedKey)
            defaults.set(english, forKey: Self.enabledKey)
            defaults.set(english, forKey: Self.autoMessagesKey)
        }
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        autoTranslateMessages = defaults.bool(forKey: Self.autoMessagesKey)
    }

    private let cache = NSCache<NSString, NSString>()
    private var activeRequests = 0

    func translateCached(_ text: String, from: String = "ru", to: String = "en") async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = "\(from)-\(to)-\(trimmed)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit.length > 0 ? hit as String : nil
        }
        // Never flood the network while a list is scrolling.
        while activeRequests >= 2 {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        activeRequests += 1
        defer { activeRequests -= 1 }
        guard let result = await translate(trimmed, from: from, to: to) else { return nil }
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    /// Enables both switches automatically when the system language is English
    /// and the user has not overridden them manually.
    func applySystemLanguageDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "translationUserOverride") else { return }
        let english = Locale.preferredLanguages.first?.lowercased().hasPrefix("en") ?? false
        guard english else { return }
        if !isEnabled { isEnabled = true }
        if !autoTranslateMessages { autoTranslateMessages = true }
    }

    var appLocale: Locale {
        isEnabled ? Locale(identifier: "en") : Locale(identifier: "ru")
    }

    func translate(_ text: String, from: String = "ru", to: String = "en") async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: "https://api.mymemory.translated.net/get?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&langpair=\(from)%7C\(to)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = object["responseData"] as? [String: Any],
                  let translated = response["translatedText"] as? String else { return nil }
            let result = translated
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
            return result.isEmpty ? nil : result
        } catch {
            return nil
        }
    }
}

/// Translates user content (chat titles, captions) when auto-translation is on.
/// Uses a shared cache and only fetches once per text.
struct TranslatedTextView: View {
    let text: String
    var font: Font? = nil
    var lineLimit: Int? = nil

    @ObservedObject private var translation = TranslationService.shared
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        Group {
            if translation.autoTranslateMessages, containsCyrillic, let result {
                Text(result)
                    .font(font)
                    .lineLimit(lineLimit)
                    .foregroundColor(.secondary)
            }
        }
        .task(id: "\(text)-\(translation.autoTranslateMessages)") {
            guard translation.autoTranslateMessages, containsCyrillic else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            if let cached = await translation.translateCached(text) {
                result = cached
            } else {
                failed = true
            }
        }
    }

    private var containsCyrillic: Bool {
        text.range(of: "[а-яА-ЯёЁ]", options: .regularExpression) != nil
    }
}
