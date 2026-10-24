import Foundation
import Combine
import UIKit
import AVFoundation
import TDLibKit

/// A track stored in the app's own music library.
struct MusicTrack: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var artist: String
    let fileName: String
    var addedAt: Foundation.Date
    /// nil for the main library; chat/channel ID for imported music.
    var sourceChatId: Int64?
    var sourceTitle: String?
    var telegramFileID: Int?
    var lastPlayedAt: Foundation.Date?
    var artworkFileName: String?
    var duration: Int?
    var isFavorite: Bool?
}

/// Device-local music library. Files are copied into Documents/MusicLibrary so
/// they remain available even if the Telegram cache is cleared.
@MainActor
final class MusicLibrary: ObservableObject {
    static let shared = MusicLibrary()

    @Published private(set) var tracks: [MusicTrack] = []
    @Published var errorText: String?
    @Published private(set) var isImporting = false
    @Published private(set) var importProgress = ""
    private var cancelImportRequested = false

    private let fileManager = FileManager.default
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus", "wma", "caf"
    ]

    let directory: URL

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("MusicLibrary", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        load()
    }

    func url(for track: MusicTrack) -> URL {
        directory.appendingPathComponent(track.fileName)
    }

    func artworkURL(for track: MusicTrack) -> URL? {
        guard let name = track.artworkFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func track(forTelegramFileID id: Int) -> MusicTrack? {
        tracks.first { $0.telegramFileID == id }
    }

    /// Returns the library track for a Telegram audio message, importing it first
    /// when needed. Used by chat audio rows and the global player.
    @discardableResult
    func ensureImported(audio: TDLibKit.Audio) async -> MusicTrack? {
        if let existing = track(forTelegramFileID: audio.audio.id) { return existing }
        await importTelegram(audio: audio, telegramFileID: audio.audio.id)
        return track(forTelegramFileID: audio.audio.id)
    }

    func importFiles(_ urls: [URL]) async {
        for url in urls {
            importFile(url)
        }
    }

    @discardableResult
    func importTelegram(
        audio: TDLibKit.Audio,
        sourceChatId: Int64? = nil,
        sourceTitle: String? = nil,
        telegramFileID: Int? = nil
    ) async -> Bool {
        if let telegramFileID, tracks.contains(where: { $0.telegramFileID == telegramFileID }) {
            return false
        }
        guard let source = await TelegramClient.shared.localFileURL(audio.audio) else {
            errorText = "Не удалось скачать аудио"
            return false
        }
        let title = audio.title.isEmpty ? audio.fileName : audio.title
        var artwork: UIImage?
        if let cover = audio.albumCoverThumbnail?.file ?? audio.externalAlbumCovers.first?.file,
           let coverURL = await TelegramClient.shared.localFileURL(cover) {
            artwork = UIImage(contentsOfFile: coverURL.path)
        }
        return copyIntoLibrary(
            source: source,
            title: title.isEmpty ? "Аудио" : title,
            artist: audio.performer,
            sourceChatId: sourceChatId,
            sourceTitle: sourceTitle,
            telegramFileID: telegramFileID,
            artwork: artwork,
            duration: audio.duration
        )
    }

    /// Imports every audio file from a chat/channel into the main library or
    /// the separate "Из чатов" tab.
    func importChat(chatId: Int64, title: String, toMain: Bool) async {
        cancelImportRequested = false
        isImporting = true
        importProgress = "Поиск аудио…"
        defer {
            isImporting = false
            importProgress = ""
        }

        let messages = await TelegramClient.shared.audioMessages(chatId: chatId)
        guard !messages.isEmpty else {
            errorText = "В этом чате не найдено аудио"
            return
        }

        var added = 0
        for (index, message) in messages.enumerated() {
            if cancelImportRequested {
                errorText = "Импорт остановлен"
                return
            }
            importProgress = "\(index + 1) из \(messages.count)"
            switch message.content {
            case .messageAudio(let audio):
                if await importTelegram(
                    audio: audio.audio,
                    sourceChatId: toMain ? nil : chatId,
                    sourceTitle: toMain ? nil : title,
                    telegramFileID: audio.audio.audio.id
                ) {
                    added += 1
                }
            case .messageDocument(let doc):
                if await importAudioDocument(
                    doc.document,
                    sourceChatId: toMain ? nil : chatId,
                    sourceTitle: toMain ? nil : title
                ) {
                    added += 1
                }
            default:
                continue
            }
        }
        errorText = added > 0 ? nil : "Все треки уже есть в библиотеке"
    }

    /// Imports a document whose extension is a known audio format (wav/ogg/…).
    private func importAudioDocument(
        _ document: TDLibKit.Document,
        sourceChatId: Int64?,
        sourceTitle: String?
    ) async -> Bool {
        let ext = (document.fileName as NSString).pathExtension.lowercased()
        guard Self.audioExtensions.contains(ext) else { return false }
        if tracks.contains(where: { $0.telegramFileID == document.document.id }) { return false }
        guard let source = await TelegramClient.shared.localFileURL(document.document) else { return false }
        let title = document.fileName.isEmpty ? "Аудио" : (document.fileName as NSString).deletingPathExtension
        return copyIntoLibrary(
            source: source,
            title: title,
            artist: "",
            sourceChatId: sourceChatId,
            sourceTitle: sourceTitle,
            telegramFileID: document.document.id,
            artwork: nil
        )
    }

    func importSavedMessagesMusic() async {
        guard let me = TelegramClient.shared.me else {
            errorText = "Профиль ещё не загружен"
            return
        }
        await importChat(chatId: me.id, title: "Из избранного", toMain: false)
    }

    /// Imports Telegram profile audio files into the main music library.
    @discardableResult
    func importProfileAudios(_ audios: [TDLibKit.Audio]) async -> Int {
        var added = 0
        for audio in audios {
            if await importTelegram(audio: audio, telegramFileID: audio.audio.id) {
                added += 1
            }
        }
        return added
    }

    func cancelImport() {
        cancelImportRequested = true
        importProgress = "Остановка…"
    }

    func deleteAll() {
        for track in tracks {
            try? fileManager.removeItem(at: url(for: track))
            if let artwork = artworkURL(for: track) {
                try? fileManager.removeItem(at: artwork)
            }
        }
        tracks = []
        errorText = nil
        save()
    }

    func markPlayed(_ track: MusicTrack) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].lastPlayedAt = Foundation.Date()
        save()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where tracks.indices.contains(index) {
            let track = tracks.remove(at: index)
            try? fileManager.removeItem(at: url(for: track))
        }
        save()
    }

    func toggleFavorite(_ track: MusicTrack) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].isFavorite = !(tracks[index].isFavorite ?? false)
        save()
    }

    func updateMetadata(
        _ track: MusicTrack,
        title: String,
        artist: String,
        artwork: UIImage?,
        removeArtwork: Bool
    ) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].title = title.isEmpty ? "Аудио" : title
        tracks[index].artist = artist

        if removeArtwork, let old = artworkURL(for: track) {
            try? fileManager.removeItem(at: old)
            tracks[index].artworkFileName = nil
        } else if let artwork, let data = artwork.jpegData(compressionQuality: 0.9) {
            if let old = artworkURL(for: track) {
                try? fileManager.removeItem(at: old)
            }
            let name = "artwork-\(UUID().uuidString).jpg"
            let url = directory.appendingPathComponent(name)
            if (try? data.write(to: url, options: .atomic)) != nil {
                try? fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
                tracks[index].artworkFileName = name
            }
        }
        save()
    }

    func delete(_ track: MusicTrack) {
        tracks.removeAll { $0.id == track.id }
        try? fileManager.removeItem(at: url(for: track))
        if let artwork = artworkURL(for: track) {
            try? fileManager.removeItem(at: artwork)
        }
        save()
    }

    private func importFile(_ source: URL) {
        let ext = source.pathExtension.lowercased()
        guard Self.audioExtensions.contains(ext) else {
            errorText = "Файл не похож на аудио: \(source.lastPathComponent)"
            return
        }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: source)
        let metadataArtwork = asset.commonMetadata
            .first(where: { $0.commonKey?.rawValue == "artwork" })?
            .dataValue
            .flatMap(UIImage.init(data:))
        let duration = Int(asset.duration.seconds.rounded())
        copyIntoLibrary(
            source: source,
            title: source.deletingPathExtension().lastPathComponent,
            artist: "",
            artwork: metadataArtwork,
            duration: duration > 0 ? duration : nil
        )
    }

    @discardableResult
    private func copyIntoLibrary(
        source: URL,
        title: String,
        artist: String,
        sourceChatId: Int64? = nil,
        sourceTitle: String? = nil,
        telegramFileID: Int? = nil,
        artwork: UIImage? = nil,
        duration: Int? = nil
    ) -> Bool {
        if let telegramFileID, tracks.contains(where: { $0.telegramFileID == telegramFileID }) {
            return false
        }
        let ext = source.pathExtension.isEmpty ? "mp3" : source.pathExtension
        let fileName = UUID().uuidString + "." + ext
        let destination = directory.appendingPathComponent(fileName)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )

            var artworkFileName: String?
            if let artwork, let data = artwork.jpegData(compressionQuality: 0.9) {
                let name = "artwork-\(UUID().uuidString).jpg"
                let artworkURL = directory.appendingPathComponent(name)
                if (try? data.write(to: artworkURL, options: .atomic)) != nil {
                    try? fileManager.setAttributes(
                        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                        ofItemAtPath: artworkURL.path
                    )
                    artworkFileName = name
                }
            }

            let track = MusicTrack(
                id: UUID().uuidString,
                title: title,
                artist: artist,
                fileName: fileName,
                addedAt: Foundation.Date(),
                sourceChatId: sourceChatId,
                sourceTitle: sourceTitle,
                telegramFileID: telegramFileID,
                lastPlayedAt: nil,
                artworkFileName: artworkFileName,
                duration: duration
            )
            tracks.insert(track, at: 0)
            errorText = nil
            save()
            return true
        } catch {
            errorText = "Не удалось добавить трек: \(error.localizedDescription)"
            return false
        }
    }

    private var storeURL: URL {
        directory.appendingPathComponent("library.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([MusicTrack].self, from: data) else { return }
        tracks = stored.filter { fileManager.fileExists(atPath: url(for: $0).path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        let url = storeURL
        // Disk I/O on the E-core lane; the main thread never waits for it.
        HardwareQueues.storage.async {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        }
    }
}
