import Foundation
import Combine

/// Routes t.me / telegram.me / tg:// links into the app instead of Safari.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var pendingUsername: String?

    private init() {}

    /// Returns true when the URL was handled by the app.
    func handle(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host == "t.me" || host == "telegram.me" || host == "www.t.me" {
            let name = url.pathComponents.dropFirst().first ?? ""
            if !name.isEmpty {
                pendingUsername = name
                return true
            }
        }
        if url.scheme?.lowercased() == "tg" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let domain = components.queryItems?.first(where: { $0.name == "domain" })?.value {
                pendingUsername = domain
                return true
            }
        }
        return false
    }
}
