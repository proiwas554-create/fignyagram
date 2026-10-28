import SwiftUI
import UIKit
import TDLibKit

/// Sticker panel for the current chat: installed sets, favorites and recent.
struct StickerPickerView: View {
    let chatId: Int64

    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var gifLibrary = GifLibrary.shared
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case sets, favorites, recent, gifs
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sets: return "Наборы"
            case .favorites: return "Избранные"
            case .recent: return "Недавние"
            case .gifs: return "Гифки"
            }
        }
    }

    @State private var tab: Tab = .sets
    @State private var sets: [StickerSetInfo] = []
    @State private var selectedSetId: TdInt64?
    @State private var stickers: [Sticker] = []
    @State private var favorites: [Sticker] = []
    @State private var recent: [Sticker] = []
    @State private var isLoading = false
    @State private var isLoadingFavorites = false
    @State private var isLoadingRecent = false
    @State private var errorText: String?
    @State private var gifFilter = 0
    @State private var previewSetId: TdInt64?
    @State private var telegramGifs: [TDLibKit.Animation] = []
    @State private var isLoadingGifs = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                tabContent
            }
            .navigationTitle(L10n.t("Auto.301763c9c8"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { previewSetId.map(StickerSetIdentified.init) },
                set: { previewSetId = $0?.value }
            )) { target in
                StickerSetView(setId: target.value, chatId: chatId)
            }
            .task {
                await loadAll()
                await loadTelegramGifs()
            }
            .onChange(of: tab) { newTab in
                Task {
                    if newTab == .favorites && favorites.isEmpty { await loadFavorites() }
                    if newTab == .recent && recent.isEmpty { await loadRecent() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .sets:
            setsContent
        case .favorites:
            gridContent(
                favorites,
                isLoading: isLoadingFavorites,
                emptyText: NSLocalizedString("Generated.fc16f5a068e9", comment: "")
            )
        case .recent:
            gridContent(
                recent,
                isLoading: isLoadingRecent,
                emptyText: NSLocalizedString("Generated.81c7637f13b3", comment: "")
            )
        case .gifs:
            gifContent
        }
    }

    @ViewBuilder
    private var gifContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $gifFilter) {
                Text(L10n.t("Auto.2b56e539f3")).tag(0)
                Text(L10n.t("Auto.83c8b9632d")).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if gifFilter == 0 {
                if isLoadingGifs && telegramGifs.isEmpty {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if telegramGifs.isEmpty {
                    Spacer()
                    Text(L10n.t("Auto.5835924ef2"))
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Spacer()
                } else {
                    gifGrid {
                        ForEach(telegramGifs, id: \.animation.id) { animation in
                            TelegramGifCell(animation: animation) {
                                sendTelegramGif(animation)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task {
                                        await client.removeSavedAnimation(animation)
                                        await loadTelegramGifs()
                                    }
                                } label: {
                                    Label(L10n.t("Auto.729c583c40"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            } else if gifLibrary.recent.isEmpty {
                Spacer()
                Text(L10n.t("Auto.fb2d59cbdf"))
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                gifGrid {
                    ForEach(gifLibrary.recent) { gif in
                        SavedGifCell(gif: gif) {
                            gifLibrary.markUsed(gif)
                            client.sendGif(gif, to: chatId)
                            dismiss()
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                gifLibrary.delete(gif)
                            } label: {
                                Label(L10n.t("Auto.2ea6230ef2"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func gifGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
                spacing: 8
            ) {
                content()
            }
            .padding(10)
        }
    }

    private func sendTelegramGif(_ animation: TDLibKit.Animation) {
        Task {
            await client.sendAnimation(animation, to: chatId)
            if await gifLibrary.save(animation), let saved = gifLibrary.items.first(where: { $0.sourceFileID == animation.animation.id }) {
                gifLibrary.markUsed(saved)
            }
        }
        dismiss()
    }

    private func loadTelegramGifs() async {
        guard !isLoadingGifs else { return }
        isLoadingGifs = true
        telegramGifs = await client.savedAnimations()
        isLoadingGifs = false
    }

    private var setsContent: some View {
        VStack(spacing: 0) {
            if !sets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(sets, id: \.id) { set in
                            Button {
                                select(set.id)
                            } label: {
                                Text(set.title.isEmpty ? NSLocalizedString("Generated.1d98103f5ac1", comment: "") : set.title)
                                    .font(.appFootnote)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(
                                            selectedSetId == set.id
                                                ? Color.accentColor.opacity(0.2)
                                                : Color(.secondarySystemBackground)
                                        )
                                    )
                                    .foregroundColor(selectedSetId == set.id ? .accentColor : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            gridContent(stickers, isLoading: isLoading, emptyText: errorText ?? NSLocalizedString("Generated.1f47fcc102d5", comment: ""))
        }
    }

    @ViewBuilder
    private func gridContent(_ list: [Sticker], isLoading: Bool, emptyText: String) -> some View {
        if isLoading && list.isEmpty {
            Spacer()
            ProgressView()
            Spacer()
        } else if list.isEmpty {
            Spacer()
            Text(emptyText)
                .font(.appFootnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 76), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(list, id: \.id) { sticker in
                        StickerCell(sticker: sticker, onTap: {
                            send(sticker)
                        }, onPreview: {
                            if sticker.setId != 0 { previewSetId = sticker.setId }
                        })
                    }
                }
                .padding(10)
            }
        }
    }

    private func send(_ sticker: Sticker) {
        client.sendSticker(sticker, to: chatId)
        client.recordStickerUsage(sticker)
        dismiss()
    }

    private func loadAll() async {
        await loadSets()
        await loadFavorites()
        await loadRecent()
    }

    private func loadSets() async {
        isLoading = true
        errorText = nil
        do {
            let loaded = try await client.installedStickerSets()
            sets = loaded
            if let first = loaded.first {
                select(first.id)
            }
        } catch {
            errorText = TelegramClient.describe(error)
        }
        isLoading = false
    }

    private func loadFavorites() async {
        guard !isLoadingFavorites else { return }
        isLoadingFavorites = true
        favorites = (try? await client.favoriteStickers()) ?? []
        isLoadingFavorites = false
    }

    private func loadRecent() async {
        guard !isLoadingRecent else { return }
        isLoadingRecent = true
        recent = (try? await client.recentStickers()) ?? []
        isLoadingRecent = false
    }

    private func select(_ id: TdInt64) {
        selectedSetId = id
        stickers = []
        isLoading = true
        errorText = nil
        Task {
            do {
                let set = try await client.stickerSet(id: id)
                guard selectedSetId == id else { return }
                stickers = set.stickers
            } catch {
                guard selectedSetId == id else { return }
                errorText = TelegramClient.describe(error)
            }
            if selectedSetId == id {
                isLoading = false
            }
        }
    }
}

private struct TelegramGifCell: View {
    let animation: TDLibKit.Animation
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.black.opacity(0.75)
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: animation.thumbnail?.file.id) {
            guard let file = animation.thumbnail?.file,
                  let url = await TelegramClient.shared.localFileURL(file) else {
                image = nil
                return
            }
            image = await ImageCache.imageAsync(atPath: url.path, maxPixel: 300)
        }
    }
}

private struct SavedGifCell: View {
    let gif: SavedGif
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.black.opacity(0.75)
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: gif.thumbnailFileName) {
            guard let url = GifLibrary.shared.thumbnailURL(for: gif) else {
                image = nil
                return
            }
            image = await ImageCache.imageAsync(atPath: url.path, maxPixel: 300)
        }
    }
}

private struct StickerCell: View {
    let sticker: Sticker
    let onTap: () -> Void
    var onPreview: (() -> Void)? = nil

    @ObservedObject private var files = FileStore.shared
    @State private var image: UIImage?

    private var path: String? {
        // Prefer the static thumbnail: TGS/WebM stickers can't be decoded by UIImage.
        if let thumbnail = sticker.thumbnail, let path = files.localPath(thumbnail.file) {
            return path
        }
        return files.localPath(sticker.sticker)
    }

    var body: some View {
        Button(action: onTap) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text(sticker.emoji.isEmpty ? "🖼" : sticker.emoji)
                        .font(.system(size: 34))
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.4) { onPreview?() }
        .task(id: path) {
            guard let path else {
                image = nil
                return
            }
            let decoded = await ImageCache.imageAsync(atPath: path, maxPixel: 280)
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .onAppear {
            TelegramClient.shared.download(sticker.sticker, priority: 8)
            if let thumbnail = sticker.thumbnail {
                TelegramClient.shared.download(thumbnail.file, priority: 8)
            }
        }
    }
}


private struct StickerSetIdentified: Identifiable {
    let value: TdInt64
    var id: TdInt64 { value }
}
