import Combine
import Foundation
import TDLibKit

/// Account-wide "recent contacts" synchronisation.
///
/// Telegram has no server object called "recent contacts", so the only way to
/// make the list travel between devices is to turn those people into real
/// Telegram contacts: they are imported with `importContacts`, and every device
/// of the account then sees them in the contact list. In the opposite direction
/// the server contact list is pulled and its users refreshed locally.
@MainActor
final class ContactsSync: ObservableObject {
    static let shared = ContactsSync()

    /// Server-side contact list, cached so it is available offline and can be
    /// shown in the contacts UI on every launch.
    @Published private(set) var serverContactIds: [Int64] = []

    private init() {
        if let cached = UserDefaults.standard.array(forKey: Keys.knownServerIds) as? [String] {
            serverContactIds = cached.compactMap(Int64.init)
        }
    }

    private enum Keys {
        static let lastSync = "contactsSyncLastRun"
        static let knownServerIds = "contactsSyncServerIds"
    }

    /// Sync at most every 10 minutes unless forced; imports are capped per run
    /// so the server never answers with FloodWait.
    private let minimumInterval: TimeInterval = 600
    private let maximumImportsPerRun = 20
    private let maximumUserRefreshesPerRun = 25

    private var isRunning = false

    func isServerContact(_ userId: Int64) -> Bool {
        serverContactIds.contains(userId)
    }

    // MARK: - Public

    /// Called when a call ends or a chat is opened: the new recent contact should
    /// reach the account soon, not only on the next cold launch.
    func scheduleSync() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.syncIfNeeded(force: false)
        }
    }

    func syncIfNeeded(force: Bool = false) async {
        guard !isRunning else { return }
        if !force, let last = UserDefaults.standard.object(forKey: Keys.lastSync) as? Foundation.Date,
           Foundation.Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        isRunning = true
        defer { isRunning = false }

        guard let client = TelegramClient.shared.tdClient else { return }

        var serverIds = Set<Int64>()
        if let users = try? await client.getContacts() {
            serverIds = Set(users.userIds)
        }
        UserDefaults.standard.set(serverIds.map(String.init), forKey: Keys.knownServerIds)
        serverContactIds = serverIds.sorted()
        await loadMissingUsers(serverIds: serverIds, client: client)

        await refreshRecentUsers(serverIds: serverIds, client: client)
        await importMissingRecents(serverIds: serverIds, client: client)

        UserDefaults.standard.set(Foundation.Date(), forKey: Keys.lastSync)
        CallDiag.log("contacts sync done: server=\(serverIds.count) recent=\(RecentContactsStore.shared.userIds.count)")
    }

    // MARK: - Directions

    /// Ensures the app has user objects for the server contacts, so the list can
    /// render names and avatars without an extra request per row.
    private func loadMissingUsers(serverIds: Set<Int64>, client: TDLibClient) async {
        var missing = serverIds.filter { ChatStore.shared.users[$0] == nil }
        var loaded = 0
        for userId in missing where loaded < 40 {
            _ = try? await client.getUser(userId: userId)
            loaded += 1
        }
        if loaded > 0 {
            CallDiag.log("contacts sync: loaded \(loaded) server contact profiles")
        }
    }

    /// Pull: make sure locally known recent contacts have fresh server data
    /// (name, username, phone) even if they were never opened in this session.
    private func refreshRecentUsers(serverIds: Set<Int64>, client: TDLibClient) async {
        var refreshed = 0
        for userId in RecentContactsStore.shared.userIds where refreshed < maximumUserRefreshesPerRun {
            guard serverIds.contains(userId) else { continue }
            if (try? await client.getUser(userId: userId)) != nil {
                refreshed += 1
            }
        }
        if refreshed > 0 {
            CallDiag.log("contacts sync: refreshed \(refreshed) server contacts")
        }
    }

    /// Push: import recent contacts that are not yet Telegram contacts, so the
    /// list becomes account-wide and appears on every device.
    private func importMissingRecents(serverIds: Set<Int64>, client: TDLibClient) async {
        var toImport: [ImportedContact] = []
        for userId in RecentContactsStore.shared.userIds
        where !serverIds.contains(userId) && toImport.count < maximumImportsPerRun {
            guard let user = ChatStore.shared.users[userId] else { continue }
            let phone = user.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty else { continue }
            let first = user.firstName.isEmpty ? (user.lastName.isEmpty ? "Contact" : user.lastName) : user.firstName
            let last = user.firstName.isEmpty ? "" : user.lastName
            toImport.append(ImportedContact(firstName: String(first.prefix(64)),
                                            lastName: String(last.prefix(64)),
                                            note: nil,
                                            phoneNumber: phone))
        }
        guard !toImport.isEmpty else { return }
        do {
            let result = try await client.importContacts(contacts: toImport)
            CallDiag.log("contacts sync: imported \(toImport.count) recent contacts, userIds=\(result.userIds.count)")
        } catch {
            // A FloodWait is expected occasionally; the next run will retry.
            CallDiag.log("contacts sync import failed \(error)")
        }
    }
}
