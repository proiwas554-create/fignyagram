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

private func thumbnailImage(_ thumbnail: Thumbnail?, minithumbnail: Minithumbnail?, store: ChatStore) -> (UIImage, Bool)? {
    if let thumbnail, let path = store.localPath(thumbnail.file), let image = ImageCache.image(atPath: path, maxPixel: 480) {
        return (image, false)
    }
    if let image = ImageCache.image(minithumbnail: minithumbnail) { return (image, true) }
    return nil
}

private func mediaFrame(width: Int, height: Int, maxWidth: CGFloat = 240) -> CGSize {
    let aspect = CGFloat(max(width, 1)) / CGFloat(max(height, 1))
    return CGSize(width: maxWidth, height: min(max(maxWidth / aspect, 80), 360))
}

enum ViewerItem: Identifiable {
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
    let photo: Photo
    @ObservedObject private var store = ChatStore.shared
    @State private var viewer: ViewerItem?

    private var size: PhotoSize? {
        let sorted = photo.sizes.sorted { $0.width < $1.width }
        return sorted.last { $0.width <= 1280 } ?? sorted.first
    }

    var body: some View {
        let frame = mediaFrame(width: size?.width ?? 1, height: size?.height ?? 1)
        let path = size.flatMap { store.localPath($0.photo) }
        Group {
            if let path, let image = ImageCache.image(atPath: path, maxPixel: 720) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let thumb = ImageCache.image(minithumbnail: photo.minithumbnail) {
                Image(uiImage: thumb).resizable().scaledToFill().blur(radius: 6)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            if let size, let progress = store.progress(size.photo) {
                ProgressRing(progress: progress)
            } else if path == nil {
                ProgressView()
            }
        }
        .onTapGesture { if let path { viewer = .image(path) } }
        .onAppear { if let size { TelegramClient.shared.download(size.photo, priority: 16) } }
        .fullScreenCover(item: $viewer) { MediaViewer(item: $0) }
    }
}

// MARK: - Video

struct VideoView: View {
    let video: Video
    @ObservedObject private var store = ChatStore.shared
    @State private var viewer: ViewerItem?

    var body: some View {
        let frame = mediaFrame(width: video.width, height: video.height)
        let path = store.localPath(video.video)
        ZStack {
            if let (image, blurred) = thumbnailImage(video.thumbnail, minithumbnail: video.minithumbnail, store: store) {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: blurred ? 6 : 0)
            } else {
                Color.black.opacity(0.6)
            }
            if let progress = store.progress(video.video) {
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
                .font(.caption2).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            if let path {
                viewer = .video(path)
            } else {
                TelegramClient.shared.download(video.video, priority: 32)
            }
        }
        .onAppear { if let t = video.thumbnail { TelegramClient.shared.download(t.file, priority: 8) } }
        .fullScreenCover(item: $viewer) { MediaViewer(item: $0) }
    }
}

// MARK: - GIF

struct AnimationView: View {
    let animation: Animation
    @ObservedObject private var store = ChatStore.shared
    @State private var looping: LoopingPlayer?

    private static let autoDownloadLimit: Int64 = 3 * 1024 * 1024

    var body: some View {
        let frame = mediaFrame(width: animation.width, height: animation.height)
        let path = store.localPath(animation.animation)
        ZStack {
            if let looping {
                PlayerLayerView(player: looping.player)
            } else if let path, animation.mimeType == "image/gif", let image = ImageCache.image(atPath: path, maxPixel: 480) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let (image, blurred) = thumbnailImage(animation.thumbnail, minithumbnail: animation.minithumbnail, store: store) {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: blurred ? 6 : 0)
            } else {
                Color.gray.opacity(0.2)
            }
            if path == nil {
                if let progress = store.progress(animation.animation) {
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
        .onTapGesture { TelegramClient.shared.download(animation.animation, priority: 32) }
        .onAppear {
            if let t = animation.thumbnail { TelegramClient.shared.download(t.file, priority: 8) }
            if animation.animation.size <= Self.autoDownloadLimit {
                TelegramClient.shared.download(animation.animation, priority: 4)
            }
            startIfReady(path)
        }
        .onChange(of: path) { startIfReady($0) }
        .onDisappear {
            looping?.player.pause()
            looping = nil
        }
    }

    private func startIfReady(_ path: String?) {
        guard looping == nil, let path, animation.mimeType != "image/gif" else { return }
        let player = LoopingPlayer(url: URL(fileURLWithPath: path))
        player.player.play()
        looping = player
    }
}

// MARK: - Sticker

struct StickerView: View {
    let sticker: Sticker
    @ObservedObject private var store = ChatStore.shared

    var body: some View {
        Group {
            if case .stickerFormatWebp = sticker.format,
               let path = store.localPath(sticker.sticker),
               let image = ImageCache.image(atPath: path, maxPixel: 320) {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let thumb = sticker.thumbnail, let path = store.localPath(thumb.file),
                      let image = ImageCache.image(atPath: path, maxPixel: 320) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(sticker.emoji.isEmpty ? "🖼" : sticker.emoji).font(.system(size: 72))
            }
        }
        .frame(width: 150, height: 150)
        .onAppear {
            if case .stickerFormatWebp = sticker.format {
                TelegramClient.shared.download(sticker.sticker, priority: 8)
            } else if let thumb = sticker.thumbnail {
                TelegramClient.shared.download(thumb.file, priority: 8)
            }
        }
    }
}

// MARK: - Voice note and music

struct VoiceNoteView: View {
    let note: VoiceNote
    let isOutgoing: Bool

    var body: some View {
        AudioRow(file: note.voice, isOutgoing: isOutgoing, duration: note.duration) { progress in
            Waveform_View(levels: Waveform.resample(Waveform.unpack(note.waveform), to: 36), progress: progress)
                .frame(width: 150, height: 24)
        }
    }
}

struct AudioFileView: View {
    let audio: Audio
    let isOutgoing: Bool

    var body: some View {
        AudioRow(file: audio.audio, isOutgoing: isOutgoing, duration: audio.duration) { _ in
            VStack(alignment: .leading, spacing: 1) {
                Text(audio.title.isEmpty ? audio.fileName : audio.title).font(.subheadline.bold()).lineLimit(1)
                if !audio.performer.isEmpty {
                    Text(audio.performer).font(.caption).lineLimit(1).opacity(0.8)
                }
            }
            .frame(maxWidth: 170, alignment: .leading)
        }
    }
}

private struct AudioRow<Middle: View>: View {
    let file: File
    let isOutgoing: Bool
    let duration: Int
    @ViewBuilder let middle: (Double) -> Middle

    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var playback = AudioPlayback.shared
    @State private var playWhenReady = false

    private var isCurrent: Bool { playback.currentFileId == file.id }

    var body: some View {
        let path = store.localPath(file)
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
                    if let progress = store.progress(file), path == nil {
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
                    .font(.caption2).opacity(0.8)
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
    let note: VideoNote
    @ObservedObject private var store = ChatStore.shared
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var playWhenReady = false

    private let side: CGFloat = 200

    var body: some View {
        let path = store.localPath(note.video)
        ZStack {
            if let player {
                PlayerLayerView(player: player)
            } else if let (image, blurred) = thumbnailImage(note.thumbnail, minithumbnail: note.minithumbnail, store: store) {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: blurred ? 4 : 0)
            } else {
                Color.gray.opacity(0.3)
            }
            if let progress = store.progress(note.video), path == nil {
                ProgressRing(progress: progress, size: 48)
            } else if !isPlaying {
                Image(systemName: "play.fill").font(.system(size: 30)).foregroundColor(.white).shadow(radius: 4)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(alignment: .bottomLeading) {
            Text(MessageFormatter.duration(note.duration))
                .font(.caption2).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                .padding(12)
        }
        .contentShape(Circle())
        .onTapGesture { toggle(path) }
        .onAppear { if let t = note.thumbnail { TelegramClient.shared.download(t.file, priority: 8) } }
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
    let document: Document
    let isOutgoing: Bool
    @ObservedObject private var store = ChatStore.shared
    @State private var previewURL: URL?
    @State private var openWhenReady = false

    var body: some View {
        let path = store.localPath(document.document)
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(isOutgoing ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.15))
                if let progress = store.progress(document.document) {
                    ProgressView(value: progress).progressViewStyle(.circular)
                } else {
                    Image(systemName: path == nil ? "arrow.down.doc" : "doc.text")
                        .font(.title3)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.fileName.isEmpty ? "Документ" : document.fileName)
                    .font(.subheadline.bold()).lineLimit(2)
                Text(MessageFormatter.fileSize(max(document.document.size, document.document.expectedSize)))
                    .font(.caption).opacity(0.8)
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
    let item: ViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            switch item {
            case .image(let path):
                if let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(MagnificationGesture()
                            .onChanged { scale = max(1, min($0, 5)) }
                            .onEnded { _ in if scale < 1.1 { withAnimation { scale = 1 } } })
                        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .video(let path):
                VideoPlayer(player: player)
                    .onAppear {
                        AudioPlayback.shared.stop()
                        try? AVAudioSession.sharedInstance().setCategory(.playback)
                        let newPlayer = AVPlayer(url: URL(fileURLWithPath: path))
                        player = newPlayer
                        newPlayer.play()
                    }
                    .onDisappear { player?.pause() }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.white, Color.black.opacity(0.5))
            }
            .padding()
        }
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
                .font(.footnote).foregroundColor(.white.opacity(0.8))
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
