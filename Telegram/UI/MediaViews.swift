import SwiftUI
import UIKit
import AVKit
import AVFoundation
import Combine
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import TDLibKit

// MARK: - Shared helpers

/// Asynchronously decoded thumbnail used as a background for videos, GIFs and round videos.
private struct MediaThumbnail: View {
    let thumbnail: TDLibKit.Thumbnail?
    let minithumbnail: TDLibKit.Minithumbnail?
    let blurRadius: CGFloat

    @ObservedObject private var files = FileStore.shared
    @State private var image: UIImage?

    private var path: String? {
        guard let thumbnail else { return nil }
        return files.localPath(thumbnail.file)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let mini = ImageCache.image(minithumbnail: minithumbnail) {
                Image(uiImage: mini).resizable().scaledToFill().blur(radius: blurRadius)
            } else {
                Color.black.opacity(0.25)
            }
        }
        .task(id: path) {
            guard let path else {
                image = nil
                return
            }
            let decoded = await ImageCache.imageAsync(atPath: path, maxPixel: 480)
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

private func mediaFrame(width: Int, height: Int, maxWidth: CGFloat = 240) -> CGSize {
    let aspect = CGFloat(max(width, 1)) / CGFloat(max(height, 1))
    return CGSize(width: maxWidth, height: min(max(maxWidth / aspect, 80), 360))
}

/// Shows percentage, downloaded/total size and estimated time left.
struct DownloadStatusView: View {
    let file: TDLibKit.File
    var compact = false
    var showCancel = true
    @ObservedObject private var files = FileStore.shared

    var body: some View {
        if let status = files.downloadStatus(file) {
            let percent = Int((status.fraction * 100).rounded())
            let text = compact
                ? "\(percent)% · \(MessageFormatter.fileSize(status.remainingBytes))"
                : "\(percent)% · \(MessageFormatter.fileSize(status.downloaded)) из \(MessageFormatter.fileSize(status.total)) · \(timeText(status.remainingSeconds))"
            HStack(spacing: 6) {
                Text(text)
                    .font(.appCaption2)
                    .foregroundColor(.secondary)
                if showCancel {
                    Button("Отменить") {
                        TelegramClient.shared.cancelDownload(file)
                    }
                    .font(.appCaption2)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func timeText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "осталось…" }
        if seconds < 60 { return "~" + "\(Int(seconds.rounded())) с" }
        return "~" + "\(Int((seconds / 60).rounded())) мин"
    }
}

/// Delays a download until the row has stayed visible for a moment, so fast
/// scrolling doesn't queue network work for media that is immediately gone.
private struct DeferredDownloadModifier: ViewModifier {
    let file: TDLibKit.File?
    let priority: Int

    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let file, FileStore.shared.localPath(file) == nil else { return }
                task?.cancel()
                task = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    TelegramClient.shared.download(file, priority: priority)
                }
            }
            .onDisappear {
                task?.cancel()
                task = nil
            }
    }
}

extension View {
    func downloadAfterDelay(_ file: TDLibKit.File?, priority: Int) -> some View {
        modifier(DeferredDownloadModifier(file: file, priority: priority))
    }
}

enum ViewerItem: Identifiable, Equatable {
    case image(String)
    case video(String)

    var id: String {
        switch self {
        case .image(let p), .video(let p): return p
        }
    }
}

// MARK: - Photo

struct PhotoView: View {
    let photo: TDLibKit.Photo
    var chatId: Int64 = 0
    var messageId: Int64 = 0
    var hasSpoiler = false
    @ObservedObject private var files = FileStore.shared
    @State private var viewer: ViewerItem?
    @State private var image: UIImage?
    @State private var revealed = false

    private var size: TDLibKit.PhotoSize? {
        let sorted = photo.sizes.sorted { $0.width < $1.width }
        return sorted.last { $0.width <= 1280 } ?? sorted.first
    }

    var body: some View {
        let frame = mediaFrame(width: size?.width ?? 1, height: size?.height ?? 1)
        let path = size.flatMap { files.localPath($0.photo) }
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let thumb = ImageCache.image(minithumbnail: photo.minithumbnail) {
                Image(uiImage: thumb).resizable().scaledToFill().blur(radius: 6)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomLeading) {
            if let size, files.downloadStatus(size.photo) != nil {
                DownloadStatusView(file: size.photo, compact: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .foregroundColor(.white)
                    .padding(6)
            }
        }
        .overlay {
            if let size, let progress = files.progress(size.photo) {
                ProgressRing(progress: progress)
            } else if path == nil {
                ProgressView()
            }
        }
        .blur(radius: hasSpoiler && !revealed ? 18 : 0)
        .overlay {
            if hasSpoiler && !revealed {
                Label("Спойлер", systemImage: "eye.slash.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundColor(.primary)
            }
        }
        .onTapGesture {
            if hasSpoiler && !revealed {
                withAnimation { revealed = true }
            } else if let path {
                viewer = .image(path)
            }
        }
        .task(id: path) {
            guard let path else {
                image = nil
                return
            }
            let decoded = await ImageCache.imageAsync(atPath: path, maxPixel: 720)
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .downloadAfterDelay(size?.photo, priority: 16)
        .fullScreenCover(item: $viewer) {
            MediaViewer(chatId: chatId, messageId: messageId, item: $0)
        }
    }
}

// MARK: - Video

struct VideoView: View {
    let video: TDLibKit.Video
    var chatId: Int64 = 0
    var messageId: Int64 = 0
    var hasSpoiler = false
    @ObservedObject private var files = FileStore.shared
    @State private var viewer: ViewerItem?
    @State private var revealed = false

    var body: some View {
        let frame = mediaFrame(width: video.width, height: video.height)
        let path = files.localPath(video.video)
        ZStack {
            MediaThumbnail(thumbnail: video.thumbnail, minithumbnail: video.minithumbnail, blurRadius: 6)
            if let progress = files.progress(video.video) {
                ProgressRing(progress: progress, size: 48)
            } else {
                Image(systemName: path == nil ? "arrow.down.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
                    .shadow(radius: 4)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .overlay(alignment: .topLeading) {
            Text("\(MessageFormatter.duration(video.duration)) · \(MessageFormatter.fileSize(video.video.size))")
                .font(.appCaption2).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(6)
        }
        .overlay(alignment: .bottomLeading) {
            if files.downloadStatus(video.video) != nil {
                DownloadStatusView(file: video.video, compact: true)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .foregroundColor(.white)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .blur(radius: hasSpoiler && !revealed ? 18 : 0)
        .overlay {
            if hasSpoiler && !revealed {
                Label("Спойлер", systemImage: "eye.slash.fill")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundColor(.primary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if hasSpoiler && !revealed {
                withAnimation { revealed = true }
            } else if let path {
                viewer = .video(path)
            } else {
                TelegramClient.shared.download(video.video, priority: 32)
            }
        }
        .downloadAfterDelay(video.thumbnail?.file, priority: 8)
        .fullScreenCover(item: $viewer) {
            MediaViewer(chatId: chatId, messageId: messageId, item: $0)
        }
    }
}

// MARK: - GIF

struct AnimationView: View {
    let gif: TDLibKit.Animation
    @ObservedObject private var files = FileStore.shared
    @State private var looping: LoopingPlayer?

    private static let autoDownloadLimit: Int64 = 3 * 1024 * 1024

    var body: some View {
        let frame = mediaFrame(width: gif.width, height: gif.height)
        let path = files.localPath(gif.animation)
        ZStack {
            if let looping {
                PlayerLayerView(player: looping.player)
            } else if let path, gif.mimeType == "image/gif", let image = ImageCache.image(atPath: path, maxPixel: 480) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                MediaThumbnail(thumbnail: gif.thumbnail, minithumbnail: gif.minithumbnail, blurRadius: 6)
            }
            if path == nil {
                if let progress = files.progress(gif.animation) {
                    ProgressRing(progress: progress)
                } else {
                    Text("GIF").font(.caption.bold()).foregroundColor(.white)
                        .padding(6).background(Capsule().fill(Color.black.opacity(0.5)))
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { TelegramClient.shared.download(gif.animation, priority: 32) }
        .onAppear {
            startIfReady(path)
        }
        .onChange(of: path) { startIfReady($0) }
        .downloadAfterDelay(gif.thumbnail?.file, priority: 8)
        .downloadAfterDelay(gif.animation.size <= Self.autoDownloadLimit ? gif.animation : nil, priority: 4)
        .onDisappear {
            looping?.player.pause()
            looping = nil
        }
    }

    private func startIfReady(_ path: String?) {
        guard looping == nil, let path, gif.mimeType != "image/gif" else { return }
        let player = LoopingPlayer(url: URL(fileURLWithPath: path))
        player.player.play()
        looping = player
    }
}

// MARK: - Sticker

struct StickerView: View {
    let sticker: TDLibKit.Sticker
    @ObservedObject private var files = FileStore.shared
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(sticker.emoji.isEmpty ? "🖼" : sticker.emoji).font(.system(size: 72))
            }
        }
        .frame(width: 150, height: 150)
        .downloadAfterDelay(downloadFile, priority: 8)
        .task(id: decodePath) {
            guard let path = decodePath else {
                image = nil
                return
            }
            let decoded = await ImageCache.imageAsync(atPath: path, maxPixel: 320)
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }

    private var decodePath: String? {
        if case .stickerFormatWebp = sticker.format, let path = files.localPath(sticker.sticker) {
            return path
        }
        if let thumb = sticker.thumbnail, let path = files.localPath(thumb.file) {
            return path
        }
        return nil
    }

    private var downloadFile: TDLibKit.File? {
        if case .stickerFormatWebp = sticker.format {
            return sticker.sticker
        }
        return sticker.thumbnail?.file
    }
}

// MARK: - Voice note and music

struct VoiceNoteView: View {
    let note: TDLibKit.VoiceNote
    let isOutgoing: Bool

    var body: some View {
        AudioRow(file: note.voice, isOutgoing: isOutgoing, duration: note.duration) { progress in
            Waveform_View(levels: Waveform.resample(Waveform.unpack(note.waveform), to: 36), progress: progress)
                .frame(width: 150, height: 24)
        }
    }
}

struct AudioFileView: View {
    let audio: TDLibKit.Audio
    let isOutgoing: Bool

    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var library = MusicLibrary.shared
    @State private var isPreparing = false

    private var track: MusicTrack? {
        library.track(forTelegramFileID: audio.audio.id)
    }

    private var isCurrent: Bool {
        player.current?.telegramFileID == audio.audio.id
    }

    var body: some View {
        HStack(spacing: 9) {
            Button(action: play) {
                ZStack {
                    Circle().fill(isOutgoing ? Color.white : Color.accentColor)
                    if isPreparing {
                        ProgressView()
                            .tint(isOutgoing ? .accentColor : .white)
                    } else {
                        Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(isOutgoing ? .accentColor : .white)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(isPreparing)

            if let track {
                MusicArtworkView(track: track, size: 34)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(audio.title.isEmpty ? audio.fileName : audio.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if !audio.performer.isEmpty {
                    Text(audio.performer)
                        .font(.appCaption)
                        .lineLimit(1)
                        .opacity(0.8)
                }
                if isCurrent {
                    ProgressView(value: player.progress)
                        .tint(isOutgoing ? .white : .accentColor)
                }
                Text(MessageFormatter.duration(isCurrent ? Int(Double(audio.duration) * player.progress) : audio.duration))
                    .font(.appCaption2)
                    .opacity(0.7)
            }
            .frame(maxWidth: 170, alignment: .leading)
        }
        .foregroundColor(isOutgoing ? .white : .primary)
    }

    private func play() {
        if isCurrent {
            player.togglePlayPause()
            return
        }
        isPreparing = true
        Task {
            if track == nil {
                await library.ensureImported(audio: audio)
            }
            if let track = library.track(forTelegramFileID: audio.audio.id) {
                AudioPlayback.shared.stop()
                player.play(track, queue: library.tracks)
            } else {
                TelegramClient.shared.errorMessage = "Не удалось открыть аудио"
            }
            isPreparing = false
        }
    }
}

private struct AudioRow<Middle: View>: View {
    let file: TDLibKit.File
    let isOutgoing: Bool
    let duration: Int
    @ViewBuilder let middle: (Double) -> Middle

    @ObservedObject private var files = FileStore.shared
    @ObservedObject private var playback = AudioPlayback.shared
    @State private var playWhenReady = false

    private var isCurrent: Bool { playback.currentFileId == file.id }

    var body: some View {
        let path = files.localPath(file)
        HStack(spacing: 10) {
            Button {
                if let path {
                    playback.toggle(fileId: file.id, path: path)
                } else {
                    playWhenReady = true
                    TelegramClient.shared.download(file, priority: 32)
                }
            } label: {
                ZStack {
                    Circle().fill(isOutgoing ? Color.white : Color.accentColor)
                    if let progress = files.progress(file), path == nil {
                        ProgressView(value: progress).progressViewStyle(.circular)
                            .tint(isOutgoing ? .accentColor : .white)
                    } else {
                        Image(systemName: isCurrent && playback.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(isOutgoing ? .accentColor : .white)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                middle(isCurrent ? playback.progress : 0)
                Text(MessageFormatter.duration(isCurrent ? Int(Double(duration) * playback.progress) : duration))
                    .font(.appCaption2).opacity(0.8)
            }
        }
        .onChange(of: path) { newPath in
            if playWhenReady, let newPath {
                playWhenReady = false
                playback.toggle(fileId: file.id, path: newPath)
            }
        }
    }
}

private struct Waveform_View: View {
    let levels: [Float]
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let barWidth = geo.size.width / CGFloat(count)
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .frame(width: max(barWidth - 1.5, 1), height: max(3, CGFloat(level) * geo.size.height))
                        .opacity(Double(index) / Double(count) < progress ? 1 : 0.4)
                        .frame(width: barWidth)
                }
            }
            .frame(height: geo.size.height)
        }
    }
}

// MARK: - Round video message

struct VideoNoteView: View {
    let note: TDLibKit.VideoNote
    @ObservedObject private var files = FileStore.shared
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playWhenReady = false

    private let side: CGFloat = 200

    var body: some View {
        let path = files.localPath(note.video)
        ZStack {
            if let player {
                PlayerLayerView(player: player)
            } else {
                MediaThumbnail(thumbnail: note.thumbnail, minithumbnail: note.minithumbnail, blurRadius: 4)
            }
            if let progress = files.progress(note.video), path == nil {
                ProgressRing(progress: progress, size: 48)
            } else if !isPlaying {
                Image(systemName: "play.fill").font(.system(size: 30)).foregroundColor(.white).shadow(radius: 4)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(alignment: .bottomLeading) {
            Text(MessageFormatter.duration(note.duration))
                .font(.appCaption2).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(12)
        }
        .contentShape(Circle())
        .onTapGesture { toggle(path) }
        .downloadAfterDelay(note.thumbnail?.file, priority: 8)
        .onChange(of: path) { newPath in
            if playWhenReady, newPath != nil {
                playWhenReady = false
                toggle(newPath)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === player?.currentItem else { return }
            stop()
        }
        .onDisappear { stop() }
    }

    private func toggle(_ path: String?) {
        guard let path else {
            playWhenReady = true
            TelegramClient.shared.download(note.video, priority: 32)
            return
        }
        if let player {
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
            return
        }
        AudioPlayback.shared.stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let newPlayer = AVPlayer(url: URL(fileURLWithPath: path))
        newPlayer.play()
        player = newPlayer
        isPlaying = true
    }

    private func stop() {
        player?.pause()
        player = nil
        isPlaying = false
    }
}

// MARK: - Document

struct DocumentView: View {
    let document: TDLibKit.Document
    let isOutgoing: Bool
    @ObservedObject private var files = FileStore.shared
    @State private var previewURL: URL?
    @State private var openWhenReady = false

    var body: some View {
        let path = files.localPath(document.document)
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(isOutgoing ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.15))
                if let progress = files.progress(document.document) {
                    ProgressView(value: progress).progressViewStyle(.circular)
                } else {
                    Image(systemName: path == nil ? "arrow.down.doc" : "doc.text")
                        .font(.appTitle3)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.fileName.isEmpty ? "Документ" : document.fileName)
                    .font(.subheadline.bold()).lineLimit(2)
                if files.downloadStatus(document.document) != nil {
                    DownloadStatusView(file: document.document, showCancel: true)
                        .opacity(0.9)
                } else {
                    Text(MessageFormatter.fileSize(max(document.document.size, document.document.expectedSize)))
                        .font(.appCaption).opacity(0.8)
                }
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if let path {
                previewURL = URL(fileURLWithPath: path)
            } else {
                openWhenReady = true
                TelegramClient.shared.download(document.document, priority: 32)
            }
        }
        .onChange(of: path) { newPath in
            if openWhenReady, let newPath {
                openWhenReady = false
                previewURL = URL(fileURLWithPath: newPath)
            }
        }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let previewURL { QuickLookView(url: previewURL).ignoresSafeArea() }
        }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// MARK: - Fullscreen viewer

struct MediaViewer: View {
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ViewerItem]
    @State private var index: Int
    @State private var shareItem: ShareItem?

    init(chatId: Int64 = 0, messageId: Int64 = 0, item: ViewerItem) {
        let gallery = chatId != 0 ? ViewerItem.gallery(chatId: chatId) : []
        var all = gallery
        if !all.contains(item) {
            all.insert(item, at: 0)
        }
        _items = State(initialValue: all.isEmpty ? [item] : all)
        _index = State(initialValue: all.firstIndex(of: item) ?? 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    page(item)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.white, Color.black.opacity(0.45))
                }
                Spacer()
                Text("\(index + 1) / \(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Button {
                    shareItem = ShareItem(url: URL(fileURLWithPath: items[index].id))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .statusBar(hidden: true)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    @ViewBuilder
    private func page(_ item: ViewerItem) -> some View {
        switch item {
        case .image(let path):
            ZoomableImageView(path: path)
        case .video(let path):
            ViewerVideoPage(path: path)
        }
    }
}

private struct ZoomableImageView: View {
    let path: String

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1), 6)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.01 {
                                    withAnimation { reset() }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                guard scale > 1.01 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            },
                        including: scale > 1.01 ? .all : .none
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1.01 {
                                reset()
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}

private struct ViewerVideoPage: View {
    let path: String
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                AudioPlayback.shared.stop()
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                let player = AVPlayer(url: URL(fileURLWithPath: path))
                self.player = player
                player.play()
            }
            .onDisappear { player?.pause() }
    }
}

extension ViewerItem {
    @MainActor
    static func gallery(chatId: Int64) -> [ViewerItem] {
        let messages = ChatStore.shared.messages[chatId] ?? []
        var result: [ViewerItem] = []
        for message in messages {
            switch message.content {
            case .messagePhoto(let photo):
                let sorted = photo.photo.sizes.sorted { $0.width < $1.width }
                if let size = sorted.last(where: { $0.width <= 1280 }) ?? sorted.first,
                   let path = FileStore.shared.localPath(size.photo) {
                    result.append(.image(path))
                }
            case .messageVideo(let video):
                if let path = FileStore.shared.localPath(video.video.video) {
                    result.append(.video(path))
                }
            case .messageAnimation(let animation):
                if let path = FileStore.shared.localPath(animation.animation.animation) {
                    result.append(.video(path))
                }
            default:
                break
            }
        }
        return result
    }
}

// MARK: - Pickers

struct PhotoPicker: UIViewControllerRepresentable {
    let onPick: ([NSItemProvider]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 10
        config.preferredAssetRepresentationMode = .compatible
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([NSItemProvider]) -> Void
        init(onPick: @escaping ([NSItemProvider]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results.map(\.itemProvider))
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

// MARK: - Round video recorder

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: CameraPreviewUIView, context: Context) {}
}

struct VideoNoteRecorderView: View {
    let onSend: (MediaPreparer.Prepared) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera = VideoNoteCamera()
    @State private var isReady = false
    @State private var isRecording = false
    @State private var isProcessing = false
    @State private var startDate = Foundation.Date()
    @State private var elapsed: Double = 0
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 32) {
            HStack {
                Button("Отмена") { close() }.foregroundColor(.white)
                Spacer()
                if isRecording {
                    Text(MessageFormatter.duration(Int(elapsed))).foregroundColor(.white).monospacedDigit()
                }
            }
            .padding(.horizontal)
            Spacer()
            ZStack {
                if isReady {
                    CameraPreview(session: camera.session)
                } else {
                    Color.gray.opacity(0.3)
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 300, height: 300)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .trim(from: 0, to: elapsed / VideoNoteCamera.maxDuration)
                    .stroke(Color.red, lineWidth: 4)
                    .rotationEffect(.degrees(-90))
            )
            Spacer()
            if isProcessing {
                ProgressView("Обработка…").tint(.white).foregroundColor(.white)
            } else {
                Button { isRecording ? stop() : start() } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                        RoundedRectangle(cornerRadius: isRecording ? 6 : 30)
                            .fill(Color.red)
                            .frame(width: isRecording ? 30 : 60, height: isRecording ? 30 : 60)
                    }
                }
                .disabled(!isReady)
            }
            Text(isRecording ? "Нажмите, чтобы отправить" : "Нажмите, чтобы записать видеосообщение")
                .font(.appFootnote).foregroundColor(.white.opacity(0.8))
        }
        .padding(.vertical)
        .background(Color.black.ignoresSafeArea())
        .onReceive(ticker) { _ in if isRecording { elapsed = Foundation.Date().timeIntervalSince(startDate) } }
        .task {
            guard await VideoNoteCamera.requestAccess() else {
                TelegramClient.shared.errorMessage = "Нет доступа к камере или микрофону. Разрешите его в Настройках."
                dismiss()
                return
            }
            camera.start { ok in
                isReady = ok
                if !ok {
                    TelegramClient.shared.errorMessage = "Камера недоступна"
                    dismiss()
                }
            }
        }
        .onDisappear { camera.shutdown() }
    }

    private func start() {
        AudioPlayback.shared.stop()
        startDate = Foundation.Date()
        elapsed = 0
        isRecording = true
        camera.startRecording { url in
            isRecording = false
            guard let url else {
                TelegramClient.shared.errorMessage = "Не удалось записать видео"
                return
            }
            isProcessing = true
            Task {
                let prepared = await MediaPreparer.videoNote(url)
                isProcessing = false
                if let prepared {
                    onSend(prepared)
                } else {
                    TelegramClient.shared.errorMessage = "Не удалось обработать видео"
                }
                close()
            }
        }
    }

    private func stop() {
        camera.stopRecording()
    }

    private func close() {
        camera.shutdown()
        dismiss()
    }
}
