import Combine
import Foundation

/// App-wide UI preferences. The interface language can follow the system or be
/// pinned to one of the bundled localizations; switching applies immediately
/// because strings are read from the matching `.lproj` bundle.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let languages: [(code: String, title: String)] = [
        ("system", "Системный / System"),
        ("ru", "Русский"),
        ("en", "English"),
        ("es", "Español"),
        ("de", "Deutsch"),
        ("zh", "中文")
    ]

    private static let languageKey = "uiLanguageOverride"

    @Published var uiLanguage: String {
        didSet {
            UserDefaults.standard.set(uiLanguage, forKey: Self.languageKey)
            objectWillChange.send()
        }
    }

    private init() {
        uiLanguage = UserDefaults.standard.string(forKey: Self.languageKey) ?? "system"
    }

    var resolvedLanguage: String {
        if uiLanguage == "system" {
            let code = Locale.preferredLanguages.first?.prefix(2).lowercased() ?? "en"
            return L10n.supported.contains(String(code)) ? String(code) : "en"
        }
        return uiLanguage
    }

    var bundle: Bundle? {
        guard let path = Bundle.main.path(forResource: resolvedLanguage, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }
}
