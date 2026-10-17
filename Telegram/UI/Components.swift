import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import ImageIO
import AVFoundation
import TDLibKit

/// Memory-bounded image cache. Images are decoded already downsampled to the size they are shown at.
enum ImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func image(atPath path: String, maxPixel: CGFloat = 1280) -> UIImage? {
        let key = "\(path)#\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    static func image(minithumbnail: TDLibKit.Minithumbnail?) -> UIImage? {
        guard let data = minithumbnail?.data else { return nil }
        return UIImage(data: data)
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

    @ObservedObject private var store = ChatStore.shared

    private static let colors: [Color] = [.red, .orange, .purple, .green, .teal, .blue, .pink]

    var body: some View {
        Group {
            if let photo, let path = store.localPath(photo.small), let image = ImageCache.image(atPath: path, maxPixel: 160) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let image = ImageCache.image(minithumbnail: photo?.minithumbnail) {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: 2)
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
        .onAppear {
            if let photo { TelegramClient.shared.download(photo.small, priority: 1) }
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

    var body: some View {
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}
