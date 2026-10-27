import Combine
import Foundation
import TDLibKit

/// Keeps self-destructing ("view once") media out of Telegram's ephemeral
/// lifecycle: as soon as TDLib hands the file to the client it is copied into a
/// private application directory, so the local copy survives the server-side
/// deletion that happens after the first view.
@MainActor
final class ViewOnceStore: ObservableObject {
    static let shared = ViewOnceStore()

    /// "chatId:messageId" -> absolute path of the preserved file.
    @Published private(set) var saved: [String: String] = [:]

    private let directory: URL
    private let indexURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("SecretMedia", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            saved = decoded
        }
    }

    static func key(chatId: Int64, messageId: Int64) -> String { "\(chatId):\(messageId)" }

    func savedPath(for message: TDLibKit.Message) -> String? {
        saved[Self.key(chatId: message.chatId, messageId: message.id)]
    }

    /// The file behind a self-destructing photo/video, if this message is one.
    static func secretFile(of message: TDLibKit.Message) -> File? {
        switch message.content {
        case .messagePhoto(let photo) where photo.isSecret:
            return photo.photo.sizes.last?.photo
        case .messageVideo(let video) where video.isSecret:
            return video.video.video
        case .messageAnimation(let animation) where animation.isSecret:
            return animation.animation.animation
        default:
            return nil
        }
    }

    /// Starts preserving the media as soon as the message arrives.
    func preserveIfNeeded(_ message: TDLibKit.Message) {
        guard let file = Self.secretFile(of: message) else { return }
        let key = Self.key(chatId: message.chatId, messageId: message.id)
        guard saved[key] == nil else { return }
        let fileName = Self.fileName(for: file, key: key)
        let destination = directory.appendingPathComponent(fileName)

        Task.detached(priority: .utility) {
            do {
                let client = await MainActor.run { TelegramClient.shared.tdClient }
                guard let client else { return }
                let downloaded = try await client.downloadFile(fileId: file.id,
                                                              limit: 0,
                                                              offset: 0,
                                                              priority: 32,
                                                              synchronous: true)
                let localPath = downloaded.local.path
                guard !localPath.isEmpty,
                      FileManager.default.fileExists(atPath: localPath) else { return }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try? FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(atPath: localPath, toPath: destination.path)
                await MainActor.run {
                    ViewOnceStore.shared.record(key: key, path: destination.path)
                }
            } catch {
                CallDiag.log("view-once preserve failed message=\(message.id) error=\(error)")
            }
        }
    }

    func clearAll() {
        for path in saved.values {
            try? FileManager.default.removeItem(atPath: path)
        }
        saved.removeAll()
        try? Data().write(to: indexURL)
        CallDiag.log("view-once storage cleared")
    }

    private func record(key: String, path: String) {
        saved[key] = path
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: indexURL, options: .atomic)
        }
        CallDiag.log("view-once preserved key=\(key) path=\(path)")
    }

    private static func fileName(for file: File, key: String) -> String {
        let remote = (file.remote as? RemoteFile)?.uniqueId ?? ""
        let ext = (remote as NSString).pathExtension
        return ext.isEmpty ? key : "\(key).\(ext)"
    }
}


import QuickLook
import SwiftUI

/// Read-only preview of a preserved self-destructing file.
struct SecretMediaPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
