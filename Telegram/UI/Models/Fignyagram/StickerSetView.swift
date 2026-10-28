import SwiftUI
import TDLibKit

struct StickerSetView: View {
    let setId: TdInt64
    var initialTitle = "Набор стикеров"
    var chatId: Int64 = 0

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var set: StickerSet?
    @State private var errorText: String?
    @State private var pendingSticker: Sticker?

    var body: some View {
        NavigationView {
            Group {
                if let set {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 10)], spacing: 10) {
                            ForEach(set.stickers, id: \.id) { sticker in
                                StickerPreviewTile(sticker: sticker) {
                                    guard chatId != 0 else { return }
                                    pendingSticker = sticker
                                }
                            }
                        }
                        .padding(12)
                    }
                } else if let errorText {
                    Text(errorText).foregroundColor(.secondary).padding()
                } else {
                    ProgressView("Загрузка набора…")
                }
            }
            .navigationTitle(set?.title ?? initialTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .confirmationDialog("Отправить стикер?", isPresented: Binding(
                get: { pendingSticker != nil },
                set: { if !$0 { pendingSticker = nil } }
            ), titleVisibility: .visible) {
                if let sticker = pendingSticker {
                    Button(L10n.t("Common.Send")) {
                        TelegramClient.shared.sendSticker(sticker, to: chatId)
                        pendingSticker = nil
                    }
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) { pendingSticker = nil }
            } message: {
                Text("Стикер будет отправлен в текущий чат.")
            }
            .task {
                do { set = try await client.stickerSet(id: setId) }
                catch { errorText = TelegramClient.describe(error) }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct StickerPreviewTile: View {
    let sticker: Sticker
    let onLongPress: () -> Void
    @ObservedObject private var files = FileStore.shared
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let thumb = sticker.thumbnail, let path = files.localPath(thumb.file),
                      let image = ImageCache.image(atPath: path, maxPixel: 220) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Text(sticker.emoji.isEmpty ? "🖼" : sticker.emoji).font(.system(size: 34))
            }
        }
        .frame(width: 82, height: 82)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.4) { onLongPress() }
        .modifier(ZoomableStickerModifier())
        .task(id: sticker.sticker.id) {
            TelegramClient.shared.download(sticker.sticker, priority: 8)
            if let thumb = sticker.thumbnail {
                TelegramClient.shared.download(thumb.file, priority: 8)
                if let path = files.localPath(thumb.file) {
                    image = await ImageCache.imageAsync(atPath: path, maxPixel: 220)
                }
            }
        }
    }
}
