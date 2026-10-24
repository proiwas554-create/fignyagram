import Foundation
import Combine

struct SharedPayload: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let url: URL?
    let files: [URL]
    var manifestName: String? = nil

    var combinedText: String {
        [text, url?.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

@MainActor
final class ShareInbox: ObservableObject {
    static let shared = ShareInbox()
    private let groupID = "group.com.Fignyagram.Fignyagram"

    @Published var payload: SharedPayload?
    private var handledTokens: Set<String> = []
    private var lastManifestName: String?
    private var pendingWasSent = false

    private init() {}

    private var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }

    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "fignyagram",
              url.host?.lowercased() == "share" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let text = items.first(where: { $0.name == "text" })?.value ?? ""
        let urlValue = items.first(where: { $0.name == "url" })?.value
        let token = items.first(where: { $0.name == "token" })?.value

        if let token {
            if handledTokens.contains(token) {
                if payload == nil {
                    if let directory {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("pending-\(token).json.dismissed.flag"))
            }
            let pending = "pending-\(token).json"
            let dismissed = pending + ".dismissed"
            let name = (directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(pending).path) } ?? false)
                ? pending
                : (directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(dismissed).path) } ?? false ? dismissed : pending)
            loadManifest(named: name, fallbackText: text, fallbackURL: urlValue)
                }
                return
            }
            handledTokens.insert(token)
            if payload != nil, payload?.files.isEmpty == false { return }
            if let directory {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("pending-\(token).json.dismissed.flag"))
            }
            let pending = "pending-\(token).json"
            let dismissed = pending + ".dismissed"
            let name = (directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(pending).path) } ?? false)
                ? pending
                : (directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(dismissed).path) } ?? false ? dismissed : pending)
            loadManifest(named: name, fallbackText: text, fallbackURL: urlValue)
        } else if payload == nil {
            payload = SharedPayload(text: text, url: urlValue.flatMap(URL.init(string:)), files: [])
        }
    }

    /// Called when the app comes to foreground, because some share extensions
    /// cannot open the host app directly.
    /// User pressed Cancel: keep the files for an explicit "Open Fignyagram"
    /// tap, but mark the manifest as dismissed so foregrounding the app does
    /// not reopen the share sheet.
    /// Called by the sheet's onDismiss. SwiftUI nils the item binding before
    /// onDismiss fires, so we cannot rely on `payload` here.
    func handleDismiss() {
        if pendingWasSent {
            pendingWasSent = false
            payload = nil
            return
        }
        dismissCurrent()
    }

    func dismissCurrent() {
        guard let directory, let name = lastManifestName else { payload = nil; return }
        let source = directory.appendingPathComponent(name)
        let target = directory.appendingPathComponent(name + ".dismissed")
        if FileManager.default.fileExists(atPath: source.path) {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: source, to: target)
            // Belt-and-braces marker: even if a manifest copy survives a move
            // failure, loadPending must never reopen it automatically.
            try? Data().write(to: directory.appendingPathComponent(name + ".dismissed.flag"))
        }
        handledTokens.removeAll()
        payload = nil
    }

    func consume() {
        pendingWasSent = true
        guard let directory else { payload = nil; return }
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" || file.lastPathComponent.hasSuffix(".json.dismissed") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        payload = nil
    }

    func loadPending() {
        guard payload == nil, let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
              var manifest = files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path > $1.path }).last else {
            return
        }
        // Never auto-reopen a share the user explicitly cancelled.
        while FileManager.default.fileExists(atPath: manifest.path + ".dismissed.flag") {
            try? FileManager.default.removeItem(at: manifest)
            let remaining = files.filter { $0.pathExtension == "json" && $0 != manifest }
            guard let next = remaining.sorted(by: { $0.path > $1.path }).last else { return }
            manifest = next
        }
        loadManifest(named: manifest.lastPathComponent, fallbackText: "", fallbackURL: nil)
    }

    private func loadManifest(named name: String, fallbackText: String, fallbackURL: String?) {
        guard let directory else {
            payload = SharedPayload(text: fallbackText, url: fallbackURL.flatMap(URL.init(string:)), files: [])
            return
        }
        let manifestURL = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            payload = SharedPayload(text: fallbackText, url: fallbackURL.flatMap(URL.init(string:)), files: [])
            return
        }
        lastManifestName = name
        pendingWasSent = false
        let text = object["text"] as? String ?? fallbackText
        let urlString = object["url"] as? String ?? fallbackURL
        let names = object["files"] as? [String] ?? []
        let files = names.compactMap { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !files.isEmpty || payload == nil {
            payload = SharedPayload(
                text: text,
                url: urlString.flatMap(URL.init(string:)),
                files: files,
                manifestName: name
            )
        }
        // Keep the manifest until the user actually sends or explicitly discards
        // the share. A cancelled composer can then be reopened with its files.
    }
}
