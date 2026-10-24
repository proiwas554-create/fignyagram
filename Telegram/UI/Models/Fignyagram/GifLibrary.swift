import Foundation
import UIKit
import AVFoundation
import Combine
import TDLibKit

struct SavedGif: Codable, Identifiable, Equatable {
    let id: String
    let fileName: String
    let thumbnailFileName: String?
    let width: Int
    let height: Int
    let duration: Int
    let addedAt: Foundation.Date
    let sourceFileID: Int?
    var lastUsedAt: Foundation.Date?
}

/// Local library of GIF/MP4 animations saved from messages.
@MainActor
final class GifLibrary: ObservableObject {
    static let shared = GifLibrary()

    @Published private(set) var items: [SavedGif] = []
    @Published var errorText: String?

    private let fileManager = FileManager.default
    let directory: URL

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("GIFs", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        load()
    }

    func url(for gif: SavedGif) -> URL {
        directory.appendingPathComponent(gif.fileName)
    }

    func thumbnailURL(for gif: SavedGif) -> URL? {
        guard let name = gif.thumbnailFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func save(_ animation: TDLibKit.Animation) async -> Bool {
        if let sourceFileID = animation.animation.id as Int?,
           items.contains(where: { $0.sourceFileID == sourceFileID }) {
            return false
        }
        guard let source = await TelegramClient.shared.localFileURL(animation.animation) else {
            errorText = "Не удалось скачать гифку"
            return false
        }
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let id = UUID().uuidString
        let fileName = id + "." + ext
        let destination = directory.appendingPathComponent(fileName)

        do {
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        } catch {
            errorText = "Не удалось сохранить гифку: \(error.localizedDescription)"
            return false
        }

        var thumbnailName: String?
        if let thumbnail = makeThumbnail(source: destination, id: id) {
            thumbnailName = thumbnail
        }

        let gif = SavedGif(
            id: id,
            fileName: fileName,
            thumbnailFileName: thumbnailName,
            width: animation.width,
            height: animation.height,
            duration: animation.duration,
            addedAt: Foundation.Date(),
            sourceFileID: animation.animation.id,
            lastUsedAt: nil
        )
        items.insert(gif, at: 0)
        errorText = nil
        saveIndex()
        return true
    }

    var recent: [SavedGif] {
        items
            .filter { $0.lastUsedAt != nil }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
    }

    func markUsed(_ gif: SavedGif) {
        guard let index = items.firstIndex(where: { $0.id == gif.id }) else { return }
        items[index].lastUsedAt = Foundation.Date()
        saveIndex()
    }

    func delete(_ gif: SavedGif) {
        items.removeAll { $0.id == gif.id }
        try? fileManager.removeItem(at: url(for: gif))
        if let thumb = thumbnailURL(for: gif) {
            try? fileManager.removeItem(at: thumb)
        }
        saveIndex()
    }

    private func makeThumbnail(source: URL, id: String) -> String? {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let image = try? generator.copyCGImage(
            at: CMTime(seconds: 0.1, preferredTimescale: 600),
            actualTime: nil
        ), let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else {
            return nil
        }
        let name = "thumb-\(id).jpg"
        let url = directory.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        return name
    }

    private var indexURL: URL {
        directory.appendingPathComponent("gifs.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([SavedGif].self, from: data) else { return }
        items = saved.filter { fileManager.fileExists(atPath: url(for: $0).path) }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let url = indexURL
        HardwareQueues.storage.async {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }
}
