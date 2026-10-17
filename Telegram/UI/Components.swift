import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins
import TDLibKit

/// Small in-memory cache so images are not re-read from disk on every redraw.
enum ImageCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(atPath path: String) -> UIImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    static func image(minithumbnail: Minithumbnail?) -> UIImage? {
        guard let data = minithumbnail?.data else { return nil }
        return UIImage(data: data)
    }
}

struct AvatarView: View {
    let id: Int64
    let title: String
    let photo: ChatPhotoInfo?
    var size: CGFloat = 52

    @ObservedObject private var store = ChatStore.shared

    private static let colors: [Color] = [.red, .orange, .purple, .green, .teal, .blue, .pink]

    var body: some View {
        Group {
            if let photo, let path = store.localPath(photo.small), let image = ImageCache.image(atPath: path) {
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
