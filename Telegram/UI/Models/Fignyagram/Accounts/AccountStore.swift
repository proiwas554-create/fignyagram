import Foundation
import Combine

/// One Telegram account = one independent TDLib database directory.
struct AccountSlot: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var databaseDirectory: String
    var filesDirectory: String
    /// false = slot was created but login never completed; nil = legacy slot.
    var isAuthenticated: Bool? = nil
}

/// Persists account slots and the currently selected account.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    private static let accountsKey = "telegramAccounts"
    private static let currentKey = "currentTelegramAccount"
    private static let previousKey = "previousTelegramAccount"

    @Published private(set) var accounts: [AccountSlot] = []
    @Published private(set) var currentId: String = ""
    /// Account that was active before "Добавить аккаунт"; lets the user cancel.
    @Published private(set) var previousId: String?

    /// Deletes tdlib_db_* folders that no longer belong to any account slot.
    /// Dozens of stale databases slow directory scans and waste disk.
    private static var didCleanupOrphans = false

    static func cleanupOrphanDatabases() {
        guard !didCleanupOrphans else { return }
        didCleanupOrphans = true

        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let accounts = UserDefaults.standard.data(forKey: "telegramAccounts")
            .flatMap { try? JSONDecoder().decode([AccountSlot].self, from: $0) } ?? []
        // Never delete anything if the account list could not be decoded:
        // this used to remove the LIVE TDLib database right after login.
        guard !accounts.isEmpty else { return }
        let keep = Set(accounts.map { URL(fileURLWithPath: $0.databaseDirectory).lastPathComponent })
        guard let contents = try? fm.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("tdlib_db_") {
            guard !keep.contains(url.lastPathComponent) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // Only clean things untouched for at least a day, never a fresh slot.
            guard Date().timeIntervalSince(modified) > 86_400 else { continue }
            try? fm.removeItem(at: url)
            DiagnosticsLog.log("cleanup orphan db \(url.lastPathComponent)")
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.accountsKey),
           let stored = try? JSONDecoder().decode([AccountSlot].self, from: data),
           !stored.isEmpty {
            accounts = stored
        } else {
            accounts = [Self.primaryAccount()]
        }

        // Remove abandoned slots created by a cancelled/failed login.
        accounts.removeAll { $0.isAuthenticated == false }
        if accounts.isEmpty {
            accounts = [Self.primaryAccount()]
        }

        if let stored = defaults.string(forKey: Self.currentKey),
           accounts.contains(where: { $0.id == stored }) {
            currentId = stored
        } else {
            currentId = accounts[0].id
        }
        if let stored = defaults.string(forKey: Self.previousKey),
           stored != currentId,
           accounts.contains(where: { $0.id == stored }) {
            previousId = stored
        }
        save()
    }

    var current: AccountSlot {
        accounts.first { $0.id == currentId } ?? accounts[0]
    }

    @discardableResult
    func addAccount() -> AccountSlot {
        let documents = Self.documentsDirectory
        let id = UUID().uuidString
        let slot = AccountSlot(
            id: id,
            title: "Аккаунт \(accounts.count + 1)",
            databaseDirectory: documents + "/tdlib_db_\(id)",
            filesDirectory: documents + "/tdlib_files_\(id)",
            isAuthenticated: false
        )
        previousId = currentId
        accounts.append(slot)
        currentId = id
        save()
        return slot
    }

    func switchTo(id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        currentId = id
        previousId = nil
        save()
    }

    func clearPrevious() {
        previousId = nil
        save()
    }

    /// Moves an account to a different storage root (e.g. Documents is not writable).
    func relocate(id: String, databaseDirectory: String, filesDirectory: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].databaseDirectory = databaseDirectory
        accounts[index].filesDirectory = filesDirectory
        save()
    }

    func markAuthenticated(id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].isAuthenticated = true
        save()
    }

    /// Drops slots that never completed authorization. Used after login failures.
    func pruneUnauthenticated() {
        let removedCurrent = accounts.contains {
            $0.id == currentId && $0.isAuthenticated == false
        }
        accounts.removeAll { $0.isAuthenticated == false }
        if accounts.isEmpty {
            accounts = [Self.primaryAccount()]
        }
        if removedCurrent || !accounts.contains(where: { $0.id == currentId }) {
            currentId = accounts[0].id
        }
        if let previousId, !accounts.contains(where: { $0.id == previousId }) {
            self.previousId = nil
        }
        save()
    }

    func updateCurrentTitle(_ title: String) {
        guard !title.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == currentId }) else { return }
        accounts[index].title = title
        save()
    }

    /// Removes an account slot (used when the user logs out of a secondary account).
    func remove(id: String) {
        guard accounts.count > 1 else { return }
        accounts.removeAll { $0.id == id }
        if currentId == id, let first = accounts.first {
            currentId = first.id
        }
        if previousId == id {
            previousId = nil
        }
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.accountsKey)
        }
        defaults.set(currentId, forKey: Self.currentKey)
        if let previousId {
            defaults.set(previousId, forKey: Self.previousKey)
        } else {
            defaults.removeObject(forKey: Self.previousKey)
        }
    }

    private static var documentsDirectory: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    private static func primaryAccount() -> AccountSlot {
        AccountSlot(
            id: "primary",
            title: "Аккаунт 1",
            databaseDirectory: documentsDirectory + "/tdlib_db",
            filesDirectory: documentsDirectory + "/tdlib_files"
        )
    }
}
