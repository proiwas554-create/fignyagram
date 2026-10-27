import SwiftUI
import TDLibKit

/// Lightweight avatar for the legacy chat list: async decode, no FileStore
/// subscription per row (that caused scroll jank) and a bounded wait for the
/// download instead of a permanent observer.
struct LegacyAvatarView: View {
    let id: Int64
    let title: String
    let file: TDLibKit.File?
    var size: CGFloat = 48

    init(id: Int64, title: String, photo: ChatPhotoInfo?, size: CGFloat = 48) {
        self.id = id
        self.title = title
        self.file = photo?.small
        self.size = size
    }

    init(id: Int64, title: String, file: TDLibKit.File?, size: CGFloat = 48) {
        self.id = id
        self.title = title
        self.file = file
        self.size = size
    }

    @State private var image: UIImage?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(color)
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: file?.id) { await load() }
        .onDisappear { task?.cancel() }
    }

    private func load() async {
        guard let file else { return }
        let cachedPath = file.local.path
        if !cachedPath.isEmpty {
            image = await ImageCache.imageAsync(atPath: cachedPath, maxPixel: 110)
            return
        }
        TelegramClient.shared.download(file, priority: 2)
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let latest = FileStore.shared.latest(file)
            let path = latest.local.path
            if !path.isEmpty, latest.local.isDownloadingCompleted {
                image = await ImageCache.imageAsync(atPath: path, maxPixel: 110)
                return
            }
        }
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal]
        return palette[Int(abs(id % Int64(palette.count)))]
    }

    private var initials: String {
        let letters = title.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
