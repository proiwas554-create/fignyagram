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
                if file.local.path.contains("video_note") {
                    add("roundVideos", file)
                } else if file.local.path.contains("animation") || file.local.path.contains("gif") {
                    add("gifs", file)
                } else {
                    add("videos", file)
                }
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
            ("photos", NSLocalizedString("Generated.9dff61621bb9", comment: ""), "photo"),
            ("videos", NSLocalizedString("Generated.88685209b986", comment: ""), "video"),
            ("audio", NSLocalizedString("Generated.cdfbbeb4f654", comment: ""), "music.note"),
            ("documents", NSLocalizedString("Generated.5d3db31fe076", comment: ""), "doc"),
            ("stickers", NSLocalizedString("Generated.16fa88686812", comment: ""), "face.smiling"),
            ("voice", NSLocalizedString("Generated.c7cdfb688908", comment: ""), "waveform"),
            ("roundVideos", NSLocalizedString("Generated.5cf06ab0747d", comment: ""), "circle.dashed"),
            ("gifs", NSLocalizedString("Generated.3075ab1bd76b", comment: ""), "rectangle.stack")
        ]

        categories = order.map { key, title, icon in
            let stat = groups[key] ?? (0, 0)
            return Category(id: key, title: title, icon: icon, bytes: stat.bytes, count: stat.count)
        }
        categories.append(Category(id: "feed", title: L10n.t("Settings.Cache.NewsFeed"),
                                   icon: "newspaper",
                                   bytes: 0,
                                   count: NewsFeedDataManager.shared.posts.count))
        autoCleanIfNeeded()
    }

    func clear(_ category: Category) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            switch category.id {
            case "feed":
                NewsFeedDataManager.shared.clearCachedPosts()
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

    /// Clears the biggest categories when the cache grows past the configured
    /// limit (MB, 0 = off). Runs at most once every 10 minutes.
    func autoCleanIfNeeded() {
        let limitMB = UserDefaults.standard.integer(forKey: "autoCleanCacheLimitMB")
        guard limitMB > 0 else { return }
        let last = UserDefaults.standard.object(forKey: "autoCleanLastRun") as? Foundation.Date
        if let last, Foundation.Date().timeIntervalSince(last) < 600 { return }
        guard totalBytes > Int64(limitMB) * 1024 * 1024 else { return }
        UserDefaults.standard.set(Foundation.Date(), forKey: "autoCleanLastRun")
        let heaviest = categories.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(2)
        for category in heaviest {
            clear(category)
        }
        CallDiag.log("auto cache clean: limit=\(limitMB)MB cleared=\(heaviest.map(\.id))")
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

    /// Clears the in-memory feed cache as well; the feed keeps no media on disk.
    func clearFeedCache() {
        NewsFeedDataManager.shared.clearCachedPosts()
        refresh()
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
                return ["mp3", "m4a", "aac", "flac", "wav", "caf"].contains(ext)
            case "voice":
                return ["ogg", "opus"].contains(ext)
            case "roundVideos":
                return ["mp4", "mov", "m4v", "webm"].contains(ext) && file.local.path.contains("video_note")
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
