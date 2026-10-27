import Foundation
import TDLibKit

/// Two-way contact synchronisation with Telegram's servers:
/// server contacts are pulled into the local store, and recent contacts that
/// the user called are pushed as imported contacts (so they appear in Telegram
/// on every device).
@MainActor
final class ContactsSync {
    static let shared = ContactsSync()

    private var isRunning = false
    private var lastRun: Foundation.Date?

    func syncIfNeeded() {
        guard !isRunning else { return }
        if let lastRun, Foundation.Date().timeIntervalSince(lastRun) < 300 { return }
        isRunning = true
        Task {
            await sync()
            lastRun = Foundation.Date()
            isRunning = false
        }
    }

    func sync() async {
        guard let client = TelegramClient.shared.tdClient else { return }
        var serverContactIds = Set<Int64>()
        if let users = try? await client.getContacts() {
            for raw in users.userIds { serverContactIds.insert(raw) }
        }
        CallDiag.log("contacts sync: server contacts=\(serverContactIds.count)")

        var toImport: [ImportedContact] = []
        for userId in RecentContactsStore.shared.userIds where !serverContactIds.contains(userId) {
            guard let user = ChatStore.shared.users[userId] else { continue }
            let phone = user.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty else { continue }
            let first = user.firstName.isEmpty ? (user.lastName.isEmpty ? "Contact" : user.lastName) : user.firstName
            let last = user.firstName.isEmpty ? "" : user.lastName
            toImport.append(ImportedContact(firstName: String(first.prefix(64)),
                                            lastName: String(last.prefix(64)),
                                            note: nil,
                                            phoneNumber: phone))
            if toImport.count >= 50 { break }
        }
        guard !toImport.isEmpty else {
            CallDiag.log("contacts sync: nothing to import")
            return
        }
        do {
            let result = try await client.importContacts(contacts: toImport)
            CallDiag.log("contacts sync: imported=\(toImport.count) userIds=\(result.userIds.count)")
        } catch {
            CallDiag.log("contacts sync failed \(error)")
        }
    }
}
