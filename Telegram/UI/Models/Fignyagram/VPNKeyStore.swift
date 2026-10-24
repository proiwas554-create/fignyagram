import Foundation
import Combine

struct VPNKey: Codable, Identifiable, Equatable {
    let id: UUID
    let raw: String
    let addedAt: Foundation.Date

    var scheme: String {
        raw.split(separator: ":").first.map(String.init)?.lowercased() ?? "key"
    }

    var title: String {
        if scheme == "tg", let components = URLComponents(string: raw),
           let server = components.queryItems?.first(where: { $0.name == "server" })?.value {
            let port = components.queryItems?.first(where: { $0.name == "port" })?.value ?? ""
            return "MTProto · \(server):\(port)"
        }
        return scheme.uppercased() + " · " + String(raw.prefix(48))
    }

    var mtproto: (server: String, port: Int, secret: String)? {
        guard scheme == "tg", let components = URLComponents(string: raw) else { return nil }
        let items = components.queryItems ?? []
        guard let server = items.first(where: { $0.name == "server" })?.value,
              let portString = items.first(where: { $0.name == "port" })?.value,
              let port = Int(portString),
              let secret = items.first(where: { $0.name == "secret" })?.value,
              !server.isEmpty, !secret.isEmpty else { return nil }
        return (server, port, secret)
    }
}

@MainActor
final class VPNKeyStore: ObservableObject {
    static let shared = VPNKeyStore()
    private static let key = "vpnKeys"

    @Published private(set) var keys: [VPNKey] = []

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([VPNKey].self, from: data) else { return }
        keys = saved
    }

    @discardableResult
    func add(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !keys.contains(where: { $0.raw == value }) else { return false }
        keys.insert(VPNKey(id: UUID(), raw: value, addedAt: Foundation.Date()), at: 0)
        save()
        return true
    }

    func remove(_ key: VPNKey) {
        keys.removeAll { $0.id == key.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
