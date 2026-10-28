import SwiftUI
import UIKit

/// A prepared outgoing item shown in the caption composer.
struct OutgoingMedia: Identifiable {
    enum Kind {
        case photo(MediaPreparer.Prepared, UIImage)
        case video(MediaPreparer.Prepared)
        case document(URL)
    }

    let id: UUID
    var kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
    var title: String {
        switch kind {
        case .photo: return "Фото"
        case .video: return "Видео"
        case .document(let url): return url.lastPathComponent
        }
    }

    var previewImage: UIImage? {
        if case .photo(_, let image) = kind { return image }
        return nil
    }

    var isDocument: Bool {
        if case .document = kind { return true }
        return false
    }

    var isPhoto: Bool {
        if case .photo = kind { return true }
        return false
    }

    var isVideo: Bool {
        if case .video = kind { return true }
        return false
    }
}

/// Preview screen shown before sending: lets the user write a caption instead
/// of sending photos/files immediately from the system pickers.
struct MediaComposerView: View {
    let initialCaption: String
    let onSend: (String, [OutgoingMedia]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [OutgoingMedia]
    @State private var caption: String
    @State private var editingIndex: Int?

    init(items: [OutgoingMedia], initialCaption: String, onSend: @escaping (String, [OutgoingMedia]) -> Void) {
        self.initialCaption = initialCaption
        self.onSend = onSend
        _items = State(initialValue: items)
        _caption = State(initialValue: initialCaption)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            preview(item, index: index)
                        }
                    }
                    .padding(12)
                }
                .frame(height: 132)
                .background(Color(.secondarySystemBackground))

                Divider()

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $caption)
                        .frame(minHeight: 90, maxHeight: 140)
                        .padding(4)
                    if caption.isEmpty {
                        Text(L10n.t("Auto.ba2d616efc"))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 8)

                Spacer(minLength: 0)
            }
            .navigationTitle(items.count > 1 ? "Отправить \(items.count) файла" : "Отправить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Send")) {
                        onSend(caption.trimmingCharacters(in: .whitespacesAndNewlines), items)
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(isPresented: Binding(
            get: { editingIndex != nil },
            set: { if !$0 { editingIndex = nil } }
        )) {
            if let index = editingIndex, index < items.count {
                switch items[index].kind {
                case .photo(_, let image):
                    PhotoEditorView(image: image) { edited in
                        guard let prepared = MediaPreparer.photo(edited) else { return }
                        items[index] = OutgoingMedia(id: items[index].id, kind: .photo(prepared, edited))
                    }
                case .video(let prepared):
                    VideoEditorView(prepared: prepared) { updated in
                        items[index] = OutgoingMedia(id: items[index].id, kind: .video(updated))
                    }
                case .document:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func preview(_ item: OutgoingMedia, index: Int) -> some View {
        ZStack(alignment: .bottomTrailing) {
            previewContent(item)
            if item.isPhoto || item.isVideo {
                Button {
                    editingIndex = index
                } label: {
                    Image(systemName: item.isVideo ? "scissors" : "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .padding(5)
            }
        }
    }

    @ViewBuilder
    private func previewContent(_ item: OutgoingMedia) -> some View {
        Group {
            if let image = item.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if item.isDocument {
                VStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.accentColor)
                    Text(item.title)
                        .font(.appCaption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                }
                .frame(width: 100, height: 100)
                .background(Color(.tertiarySystemBackground))
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
    }
}
