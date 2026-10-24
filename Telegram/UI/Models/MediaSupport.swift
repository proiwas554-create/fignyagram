import Foundation
import Combine
import UIKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Audio playback (voice notes and music)

@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()

    /// TDLib file id of the track being played.
    @Published private(set) var currentFileId: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(fileId: Int, path: String) {
        if currentFileId == fileId, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                timer?.invalidate()
            } else {
                player.play()
                isPlaying = true
                startTimer()
            }
            return
        }
        stop()
        do {
            let url = try Self.playableURL(fileId: fileId, path: path)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            Self.activateAudioSessionOffMain()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            currentFileId = fileId
            isPlaying = true
            startTimer()
        } catch {
            TelegramClient.shared.errorMessage = "Не удалось воспроизвести аудио"
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        currentFileId = nil
        isPlaying = false
        progress = 0
        Self.deactivateAudioSessionOffMain()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        }
    }

    /// AVAudioSession.setActive on the main thread can stall the UI for
    /// hundreds of milliseconds; route the blocking call off-main.
    static func activateAudioSessionOffMain() {
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    static func deactivateAudioSessionOffMain() {
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    /// Telegram voice notes are Ogg/Opus; they are re-wrapped into CAF once and cached.
    private static func playableURL(fileId: Int, path: String) throws -> URL {
        let source = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: source)
        let magic = handle.readData(ofLength: 4)
        try? handle.close()
        guard magic == Data("OggS".utf8) else { return source }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("voice", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(fileId).caf")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try OggOpus.convertOggToCaf(source, destination: destination)
        }
        return destination
    }
}

// MARK: - Voice recording

struct VoiceRecording {
    let url: URL
    let duration: Int
    let waveform: Data
}

@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var levels: [Float] = []

    func start() async -> Bool {
        guard await Self.requestPermission() else {
            TelegramClient.shared.errorMessage = "Нет доступа к микрофону. Разрешите его в Настройках."
            return false
        }
        AudioPlayback.shared.stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        AudioPlayback.activateAudioSessionOffMain()

        // Opus is what Telegram expects; AAC is a fallback for devices where Opus recording fails.
        let opus: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ]
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ]
        var started: AVAudioRecorder?
        for (settings, ext) in [(opus, "caf"), (aac, "m4a")] {
            if let candidate = try? AVAudioRecorder(url: TelegramClient.makeOutgoingURL(extension: ext), settings: settings) {
                candidate.isMeteringEnabled = true
                if candidate.record() {
                    started = candidate
                    break
                }
            }
        }
        guard let started else {
            TelegramClient.shared.errorMessage = "Не удалось начать запись"
            return false
        }
        recorder = started
        levels = []
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        return true
    }

    nonisolated private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (power + 50) / 50))
        level = normalized
        levels.append(normalized)
        elapsed = recorder.currentTime
    }

    func stop() -> VoiceRecording? {
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        finish()
        guard duration >= 0.7 else {
            try? FileManager.default.removeItem(at: recorder.url)
            return nil
        }
        var url = recorder.url
        if url.pathExtension == "caf" {
            let ogg = url.deletingPathExtension().appendingPathExtension("ogg")
            if (try? OggOpus.convertCafToOgg(url, destination: ogg)) != nil {
                try? FileManager.default.removeItem(at: url)
                url = ogg
            }
        }
        let peak = max(levels.max() ?? 1, 0.01)
        let waveform = Waveform.pack(Waveform.resample(levels.map { $0 / peak }, to: 63))
        return VoiceRecording(url: url, duration: max(1, Int(duration.rounded())), waveform: waveform)
    }

    func cancel() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        isRecording = false
        level = 0
        AudioPlayback.deactivateAudioSessionOffMain()
    }
}

// MARK: - Video note camera

/// Front camera capture for round video messages. Runs on its own queue.
nonisolated final class VideoNoteCamera: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "fignyagram.videonote")
    private var onFinish: ((URL?) -> Void)?
    static let maxDuration: Double = 60

    static func requestAccess() async -> Bool {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return video && audio
    }

    func start(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            let ok = configure()
            if ok { session.startRunning() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private func configure() -> Bool {
        guard session.inputs.isEmpty else { return true }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput) else { return false }
        session.addInput(videoInput)
        if let mic = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        output.maxRecordedDuration = CMTime(seconds: Self.maxDuration, preferredTimescale: 600)
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
        }
        return true
    }

    func startRecording(onFinish: @escaping (URL?) -> Void) {
        self.onFinish = onFinish
        let url = TelegramClient.makeOutgoingURL(extension: "mov")
        queue.async { [self] in output.startRecording(to: url, recordingDelegate: self) }
    }

    func stopRecording() {
        queue.async { [self] in if output.isRecording { output.stopRecording() } }
    }

    func shutdown() {
        onFinish = nil
        queue.async { [self] in
            if output.isRecording { output.stopRecording() }
            session.stopRunning()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Swift.Error?) {
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        let ok = error == nil || finished == true
        DispatchQueue.main.async { [self] in
            onFinish?(ok ? url : nil)
            onFinish = nil
        }
    }
}

// MARK: - Preparing media for upload

/// Runs off the main actor: file and media APIs call back on background threads.
nonisolated enum MediaPreparer {
    struct Prepared {
        let url: URL
        let width: Int
        let height: Int
        let duration: Int
    }

    /// Re-encodes a photo as JPEG of at most 2560 px: keeps uploads small and avoids HEIC compatibility issues.
    static func photo(_ image: UIImage) -> Prepared? {
        let maxSide: CGFloat = 2560
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }
        let url = TelegramClient.makeOutgoingURL(extension: "jpg")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return Prepared(url: url, width: Int(target.width), height: Int(target.height), duration: 0)
    }

    static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        let object = await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
        if let object { return object }
        // Some providers (e.g. shared JPEGs) don't expose a UIImage object;
        // fall back to the raw data representation.
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data.flatMap(UIImage.init(data:)))
            }
        }
    }

    /// The picker deletes its temporary file after the callback, so it is copied first.
    static func loadMovie(_ provider: NSItemProvider) async -> URL? {
        for type in [UTType.movie, UTType.video, UTType.data]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let url = await loadFile(provider, type: type.identifier) { return url }
        }
        return nil
    }

    /// Copies any provider payload (movie, video, image data) into the outgoing directory.
    static func loadFile(_ provider: NSItemProvider, type: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
                let copy = TelegramClient.makeOutgoingURL(extension: ext)
                let ok = (try? FileManager.default.copyItem(at: url, to: copy)) != nil
                continuation.resume(returning: ok ? copy : nil)
            }
        }
    }

    /// Copies the original, un-reencoded file (photos/videos sent "without compression").
    static func originalFile(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await loadFile(provider, type: type.identifier)
    }

    /// Converts a video to H.264 MP4 of at most 720p.
    static func video(_ source: URL) async -> Prepared? {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .video).first,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let url = TelegramClient.makeOutgoingURL(extension: "mp4")
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        guard await export(session) else { return nil }
        try? FileManager.default.removeItem(at: source)
        let size = track.naturalSize.applying(track.preferredTransform)
        let scale = min(1, 1280 / max(abs(size.width), abs(size.height), 1))
        return Prepared(
            url: url,
            width: Int(abs(size.width) * scale), height: Int(abs(size.height) * scale),
            duration: Int(asset.duration.seconds.rounded())
        )
    }

    /// Crops the center square of a recording and scales it to the round video message size.
    static func videoNote(_ source: URL, length: Int = 384) async -> Prepared? {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .video).first,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else { return nil }
        let oriented = track.naturalSize.applying(track.preferredTransform)
        let width = abs(oriented.width)
        let height = abs(oriented.height)
        let side = min(width, height)
        let scale = CGFloat(length) / side

        let transform = track.preferredTransform
            .concatenating(CGAffineTransform(translationX: -(width - side) / 2, y: -(height - side) / 2))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: length, height: length)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]

        let url = TelegramClient.makeOutgoingURL(extension: "mp4")
        session.videoComposition = composition
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        guard await export(session) else { return nil }
        try? FileManager.default.removeItem(at: source)
        return Prepared(url: url, width: length, height: length, duration: max(1, Int(asset.duration.seconds.rounded())))
    }

    private static func export(_ session: AVAssetExportSession) async -> Bool {
        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume(returning: session.status == .completed)
            }
        }
    }

    /// Copies a picked document into the outgoing directory keeping its file name.
    static func document(_ source: URL) -> URL? {
        let directory = TelegramClient.outgoingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        return (try? FileManager.default.copyItem(at: source, to: destination)) != nil ? destination : nil
    }
}
