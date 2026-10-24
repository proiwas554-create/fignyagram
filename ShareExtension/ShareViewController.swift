import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let openButton = UIButton(type: .system)
    private let groupID = "group.com.Fignyagram.Fignyagram"
    private var sharedURL: URL?
    private var didFinish = false
    private let stateLock = NSLock()
    private var collectedFiles: [String] = []
    private var collectedText: String?
    private var collectedURL: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Подготовка файлов для Fignyagram…"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        openButton.setTitle("Открыть Fignyagram", for: .normal)
        openButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        openButton.addTarget(self, action: #selector(tapOpen), for: .touchUpInside)
        openButton.isHidden = true
        openButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(openButton)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16)
        ])
        process()
    }

    private func process() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let url = item as? URL, let name = self.copyToGroup(url, preferred: url.lastPathComponent) else { return }
                    self.addFile(name)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = item as? URL { self.setURL(url.absoluteString) }
                    else if let string = item as? String { self.setURL(string) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let string = item as? String { self.setText(string) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
                        provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ||
                        provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                group.enter()
                let type = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                    ? UTType.image.identifier
                    : (provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                        ? UTType.movie.identifier : UTType.data.identifier)
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    defer { group.leave() }
                    guard let url, let name = self.copyToGroup(url, preferred: provider.suggestedName ?? url.lastPathComponent) else { return }
                    self.addFile(name)
                }
            }
        }

        group.notify(queue: .main) {
            let (text, urlString, fileNames) = self.snapshot()
            let directories = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: self.groupID
            )
            let token = UUID().uuidString
            if let base = directories?.appendingPathComponent("ShareInbox", isDirectory: true) {
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let manifest: [String: Any] = [
                    "text": text,
                    "url": urlString,
                    "files": fileNames
                ]
                if let data = try? JSONSerialization.data(withJSONObject: manifest) {
                    try? data.write(to: base.appendingPathComponent("pending-\(token).json"))
                }
            }
            var components = URLComponents()
            components.scheme = "fignyagram"
            components.host = "share"
            components.queryItems = [
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "url", value: urlString)
            ]
            guard let url = components.url else {
                self.finish()
                return
            }
            self.sharedURL = url
            self.open(url)
        }
    }

    private func addFile(_ name: String) {
        stateLock.lock(); collectedFiles.append(name); stateLock.unlock()
    }

    private func setText(_ value: String) {
        stateLock.lock(); collectedText = value; stateLock.unlock()
    }

    private func setURL(_ value: String) {
        stateLock.lock(); collectedURL = value; stateLock.unlock()
    }

    private func snapshot() -> (String, String, [String]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (collectedText ?? "", collectedURL ?? "", collectedFiles)
    }

    private func copyToGroup(_ source: URL, preferred: String) -> String? {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        )?.appendingPathComponent("ShareInbox", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var name = preferred.isEmpty ? source.lastPathComponent : preferred
        if name.isEmpty { name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "dat" : source.pathExtension) }
        var destination = base.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            name = stem + " " + UUID().uuidString.prefix(6) + (ext.isEmpty ? "" : "." + ext)
            destination = base.appendingPathComponent(name)
        }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return name
        } catch { return nil }
    }

    @objc private func tapOpen() {
        guard let url = sharedURL else { return }
        open(url)
    }

    private func open(_ url: URL) {
        sharedURL = url
        guard let context = extensionContext else {
            openViaWorkspace(url)
            showOpenButton()
            return
        }
        context.open(url) { success in
            DispatchQueue.main.async {
                if success {
                    self.finish()
                } else {
                    self.openViaResponder(url)
                    self.openViaWorkspace(url)
                    self.showOpenButton()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !self.didFinish {
                self.openViaWorkspace(url)
                self.showOpenButton()
            }
        }
    }

    private func openViaWorkspace(_ url: URL) {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?
                .takeUnretainedValue() as? NSObject else { return }
        let selector = NSSelectorFromString("openURL:withOptions:")
        if workspace.responds(to: selector) {
            _ = workspace.perform(selector, with: url, with: nil)
        }
    }

    private func showOpenButton() {
        openButton.isHidden = false
        label.text = "Откройте Fignyagram и выберите чат для отправки."
    }

    private func openViaResponder(_ url: URL) {
        guard let appClass = NSClassFromString("UIApplication") as? NSObject.Type else { return }
        let sharedSelector = NSSelectorFromString("sharedApplication")
        guard let shared = appClass.perform(sharedSelector)?.takeUnretainedValue() as? NSObject else { return }
        let openSelector = NSSelectorFromString("openURL:")
        if shared.responds(to: openSelector) {
            _ = shared.perform(openSelector, with: url)
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        extensionContext?.completeRequest(returningItems: nil)
    }
}
