import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import ImageIO
import AVFoundation
import TDLibKit

/// Memory-bounded image cache. Images are decoded already downsampled to the size they are shown at.
/// `nonisolated` so decoding can run off the main thread without blocking scrolling.
nonisolated enum ImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        if DevicePerformance.isVeryLowMemory {
            cache.totalCostLimit = 24 * 1024 * 1024
            cache.countLimit = 150
        } else if DevicePerformance.isLowMemory {
            cache.totalCostLimit = 40 * 1024 * 1024
            cache.countLimit = 250
        } else {
            cache.totalCostLimit = 96 * 1024 * 1024
            cache.countLimit = 600
        }
        return cache
    }()

    /// Dedicated queue with a small concurrency limit: decoding never blocks main
    /// and waiting work does not occupy GCD threads like a semaphore would.
    private static let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ImageCache.decode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = DevicePerformance.isVeryLowMemory ? 1 : 2
        return queue
    }()

    /// Minithumbnails are tiny, but decoding them on every body evaluation is wasteful.
    private static let miniCache: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 500
        return cache
    }()

    /// Decodes and pre-masks an avatar into a circular bitmap on a background
    /// queue, so the main thread only blits a ready texture (no clipShape pass).
    static func circularImageAsync(atPath path: String, maxPixel: CGFloat = 160) async -> UIImage? {
        guard let image = await imageAsync(atPath: path, maxPixel: maxPixel) else { return nil }
        return await withCheckedContinuation { continuation in
            decodeQueue.addOperation {
                let side = min(image.size.width, image.size.height)
                let rect = CGRect(x: (image.size.width - side) / 2,
                                  y: (image.size.height - side) / 2,
                                  width: side, height: side)
                let format = UIGraphicsImageRendererFormat.default()
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
                let rounded = renderer.image { context in
                    UIColor.systemBackground.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                    UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
                    image.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
                }
                continuation.resume(returning: rounded)
            }
        }
    }

    static func image(atPath path: String, maxPixel: CGFloat = 1280) -> UIImage? {
        let effectiveMax = effectiveMaxPixel(maxPixel)
        let key = "\(path)#\(Int(effectiveMax))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        return autoreleasepool {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: effectiveMax,
            ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
            return image
        }
    }

    private static var hardwareMaxPixel: CGFloat = 0

    static func applyHardwareTuning(maxPixel: CGFloat, cacheMB: Int, concurrency: Int, qos: QualityOfService) {
        hardwareMaxPixel = maxPixel
        cache.totalCostLimit = cacheMB * 1024 * 1024
        cache.countLimit = concurrency == 1 ? 200 : 400
        decodeQueue.maxConcurrentOperationCount = concurrency
        decodeQueue.qualityOfService = qos
    }

    private static func effectiveMaxPixel(_ requested: CGFloat) -> CGFloat {
        if UserDefaults.standard.bool(forKey: "ultraOptimizationEnabled") {
            return min(requested, 200)
        }
        if hardwareMaxPixel > 0 {
            return min(requested, hardwareMaxPixel)
        }
        if !UserDefaults.standard.bool(forKey: "maximumPerformanceMode"),
           DevicePerformance.isLowMemory {
            return min(requested, 900)
        }
        guard UserDefaults.standard.bool(forKey: "maximumPerformanceMode") else { return requested }
        let raw = UserDefaults.standard.string(forKey: "performanceModeLevel") ?? ""
        let level = PerformanceLevel(rawValue: raw) ?? .balanced
        return min(requested, level.maxPixel)
    }

    static func setPerformanceMode(_ enabled: Bool, level: PerformanceLevel) {
        if enabled || (UserDefaults.standard.object(forKey: "ignoreCopyProtection") as? Bool ?? true) {
            cache.totalCostLimit = level.cacheLimit
            cache.countLimit = level == .maximum ? 150 : 300
            miniCache.countLimit = level == .maximum ? 150 : 350
            decodeQueue.maxConcurrentOperationCount = level.decodeConcurrency
        } else {
            cache.totalCostLimit = 64 * 1024 * 1024
            cache.countLimit = 400
            miniCache.countLimit = 500
            decodeQueue.maxConcurrentOperationCount = 2
        }
        clear()
    }

    /// Decodes an image on a background queue; the result is still cached for later rows.
    static func imageAsync(atPath path: String, maxPixel: CGFloat = 1280) async -> UIImage? {
        let effectiveMax = effectiveMaxPixel(maxPixel)
        let key = "\(path)#\(Int(effectiveMax))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let token = DecodeCancellationToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decodeQueue.addOperation {
                    guard !token.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: image(atPath: path, maxPixel: effectiveMax))
                }
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Drops decoded images on memory pressure; they are re-decoded on demand.
    static func configureForDevice() {
        guard DevicePerformance.isLowMemory else { return }
        cache.totalCostLimit = DevicePerformance.isVeryLowMemory ? 24 * 1024 * 1024 : 32 * 1024 * 1024
        cache.countLimit = 250
        miniCache.countLimit = 300
    }

    static func setUltraMode(_ enabled: Bool) {
        if enabled || (UserDefaults.standard.object(forKey: "ignoreCopyProtection") as? Bool ?? true) {
            cache.totalCostLimit = 8 * 1024 * 1024
            cache.countLimit = 60
            miniCache.countLimit = 80
            decodeQueue.maxConcurrentOperationCount = 1
            clear()
        }
    }

    static func setDecodeConcurrency(_ value: Int) {
        decodeQueue.maxConcurrentOperationCount = max(1, min(value, 4))
    }

    /// Old devices (A10 and below): one decode lane, small cache, utility QoS.
    static func applyLegacyDeviceTuning() {
        decodeQueue.maxConcurrentOperationCount = 1
        decodeQueue.qualityOfService = .utility
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 200
        miniCache.countLimit = 250
    }

    static func clear() {
        cache.removeAllObjects()
        miniCache.removeAllObjects()
    }

    /// Aggressive GC for backgrounding: cancel pending decodes and drop all
    /// decoded images. Files on disk are kept; images are re-decoded on demand.
    static func flushForBackground() {
        decodeQueue.cancelAllOperations()
        cache.removeAllObjects()
        miniCache.removeAllObjects()
    }

    static func image(minithumbnail: TDLibKit.Minithumbnail?) -> UIImage? {
        guard let data = minithumbnail?.data, !data.isEmpty else { return nil }
        let key = data as NSData
        if let cached = miniCache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        miniCache.setObject(image, forKey: key)
        return image
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

/// Muted endlessly looping player for GIFs.
final class LoopingPlayer {
    let player = AVQueuePlayer()
    private let looper: AVPlayerLooper

    init(url: URL) {
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
    }
}

struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.45))
            Circle()
                .trim(from: 0, to: max(0.03, min(progress, 1)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(5)
        }
        .frame(width: size, height: size)
    }
}

extension View {
    @ViewBuilder
    func mediumSheet() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium, .large])
        } else {
            self
        }
    }
}

struct AvatarView: View {
    let id: Int64
    let title: String
    let photo: TDLibKit.ChatPhotoInfo?
    var size: CGFloat = 52

    @ObservedObject private var files = FileStore.shared
    @State private var image: UIImage?
    @State private var downloadTask: Task<Void, Never>?

    private static let colors: [Color] = [.red, .orange, .purple, .green, .teal, .blue, .pink]

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let image = ImageCache.image(minithumbnail: photo?.minithumbnail) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: ScrollActivity.shared.isScrolling ? 0 : 2)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Self.colors[Int(abs(id % Int64(Self.colors.count)))].opacity(0.7),
                                 Self.colors[Int(abs(id % Int64(Self.colors.count)))]],
                        startPoint: .top, endPoint: .bottom
                    )
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: localPhotoPath) {
            guard let path = localPhotoPath else {
                image = nil
                return
            }
            let pixel: CGFloat = DevicePerformance.isLowMemory ? 120 : 160
            let decoded = await ImageCache.circularImageAsync(atPath: path, maxPixel: pixel)
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .onAppear(perform: scheduleDownload)
        .onDisappear {
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    private var localPhotoPath: String? {
        guard let photo else { return nil }
        return files.localPath(photo.small)
    }

    /// Avoids starting avatar downloads for rows that only flash by during a fast scroll.
    private func scheduleDownload() {
        guard let photo, localPhotoPath == nil else { return }
        downloadTask?.cancel()
        downloadTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            TelegramClient.shared.download(photo.small, priority: 1)
        }
    }

    private var initials: String {
        let words = title.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct ErrorBanner: View {
    let message: String?

    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        if let message {
            Text(message)
                .font(.appFootnote)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .onAppear { scheduleDismiss(message) }
                .onChange(of: message) { newValue in scheduleDismiss(newValue) }
                .onDisappear { dismissTask?.cancel() }
        }
    }

    private func scheduleDismiss(_ text: String) {
        dismissTask?.cancel()
        guard !text.isEmpty else { return }
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if TelegramClient.shared.errorMessage == text {
                    TelegramClient.shared.errorMessage = nil
                }
            }
        }
    }
}


/// Cancellation flag shared with a queued image decode.
private final class DecodeCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}


/// Dismisses the keyboard from anywhere.
func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil, from: nil, for: nil
    )
}


/// Applies text selection only when the user enabled it in Settings.
struct SelectableTextModifier: ViewModifier {
    @AppStorage("textSelectionEnabled") private var enabled = true

    func body(content: Content) -> some View {
        if enabled || (UserDefaults.standard.object(forKey: "ignoreCopyProtection") as? Bool ?? true) {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}
