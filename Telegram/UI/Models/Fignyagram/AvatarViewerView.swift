import SwiftUI
import TDLibKit
import UIKit

struct AvatarPhoto: Identifiable {
    let id: Int
    let file: TDLibKit.File
}

struct AvatarViewerView: View {
    let photos: [AvatarPhoto]
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var saved = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                    AvatarImagePage(file: photo.file)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                Spacer()
                Text("\(index + 1) / \(photos.count)")
                    .font(.appCaption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Button {
                    saveCurrent()
                } label: {
                    Image(systemName: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
                .accessibilityLabel("Сохранить аватарку")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .statusBar(hidden: true)
        .overlay(alignment: .bottom) {
            if saved {
                Text("Сохранено")
                    .font(.appCaption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 30)
            }
        }
    }

    private func saveCurrent() {
        guard index < photos.count else { return }
        Task {
            guard let url = await TelegramClient.shared.localFileURL(photos[index].file),
                  let image = UIImage(contentsOfFile: url.path) else { return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            saved = true
        }
    }
}

private struct AvatarImagePage: View {
    let file: TDLibKit.File
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(lastScale * value, 1), 5)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1.01 { withAnimation { scale = 1; lastScale = 1 } }
                            }
                    )
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "photo").font(.system(size: 44))
                    Text("Не удалось загрузить аватарку").font(.appFootnote)
                }
                .foregroundColor(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: file.id) {
            guard let url = await TelegramClient.shared.localFileURL(file) else {
                failed = true
                return
            }
            if let decoded = await ImageCache.imageAsync(atPath: url.path, maxPixel: 2048) {
                image = decoded
            } else {
                image = UIImage(contentsOfFile: url.path)
            }
            failed = image == nil
        }
    }
}
