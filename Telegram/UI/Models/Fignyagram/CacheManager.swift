import Foundation
import Combine
import TDLibKit

@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()

    struct Category: Identifiable {
        let id: String
        let title: String
        let icon: String
        var bytes: Int64
        var count: Int
    }

    @Published private(set) var categories: [Category] = []
    @Published private(set) var isWorking = false

    var totalBytes: Int64 {
        categories.reduce(0) { $0 + $1.bytes }
    }

    private init() {}

    func refresh() {
        let files = FileStore.shared.downloadedFiles
        var groups: [String: (bytes: Int64, count: Int)] = [:]
        func add(_ key: String, _ file: TDLibKit.File) {
            let size = max(file.size, file.expectedSize)
            groups[key, default: (0, 0)].bytes += size
            groups[key, default: (0, 0)].count += 1
        }

        for file in files {
            let ext = URL(fileURLWithPath: file.local.path).pathExtension.lowercased()
            switch ext {
            case "jpg", "jpeg", "png", "heic", "webp", "gif":
                add("photos", file)
            case "mp4", "mov", "m4v", "webm":
                add("videos", file)
            case "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "caf":
                add("audio", file)
            case "tgs":
                add("stickers", file)
            default:
                add("documents", file)
            }
        }

        let gifStats = gifDirectoryStats()
        if gifStats.count > 0 {
            groups["gifs"] = gifStats
        }

        let order: [(String, String, String)] = [
            ("photos", "Фото", "photo"),
            ("videos", "Видео", "video"),
            ("audio", "Аудио", "music.note"),
            ("documents", "Файлы", "doc"),
            ("stickers", "Стикеры", "face.smiling"),
            ("gifs", "Гифки", "rectangle.stack")
        ]

        categories = order.map { key, title, icon in
            let stat = groups[key] ?? (0, 0)
            return Category(id: key, title: title, icon: icon, bytes: stat.bytes, count: stat.count)
        }
    }

    func clear(_ category: Category) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            switch category.id {
            case "gifs":
                for gif in GifLibrary.shared.items {
                    GifLibrary.shared.delete(gif)
                }
            case "stickers":
                let files = FileStore.shared.downloadedFiles.filter {
                    URL(fileURLWithPath: $0.local.path).pathExtension.lowercased() == "tgs"
                }
                for file in files {
                    TelegramClient.shared.deleteDownloadedFile(file)
                }
            default:
                let files = matchingFiles(category.id)
                for file in files {
                    TelegramClient.shared.deleteDownloadedFile(file)
                }
            }
            ImageCache.clear()
            try? await Task.sleep(nanoseconds: 400_000_000)
            refresh()
            isWorking = false
        }
    }

    func clearAll() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            for file in FileStore.shared.downloadedFiles {
                TelegramClient.shared.deleteDownloadedFile(file)
            }
            for gif in GifLibrary.shared.items {
                GifLibrary.shared.delete(gif)
            }
            ImageCache.clear()
            ChatStore.shared.clearLoadedMessages()
            FileStore.shared.reset()
            try? await Task.sleep(nanoseconds: 400_000_000)
            refresh()
            isWorking = false
        }
    }

    private func matchingFiles(_ categoryID: String) -> [TDLibKit.File] {
        FileStore.shared.downloadedFiles.filter { file in
            let ext = URL(fileURLWithPath: file.local.path).pathExtension.lowercased()
            switch categoryID {
            case "photos":
                return ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(ext)
            case "videos":
                return ["mp4", "mov", "m4v", "webm"].contains(ext)
            case "audio":
                return ["mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "caf"].contains(ext)
            case "documents":
                return !["jpg", "jpeg", "png", "heic", "webp", "gif", "mp4", "mov", "m4v", "webm", "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav", "caf", "tgs"].contains(ext)
            default:
                return false
            }
        }
    }

    private func gifDirectoryStats() -> (bytes: Int64, count: Int) {
        let directory = GifLibrary.shared.directory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return (bytes: 0, count: 0) }
        var bytes: Int64 = 0
        var count = 0
        for file in files where file.pathExtension.lowercased() != "json" {
            bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            count += 1
        }
        return (bytes: bytes, count: count)
    }
}
