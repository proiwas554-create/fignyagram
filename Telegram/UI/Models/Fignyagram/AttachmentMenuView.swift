import SwiftUI

enum AttachmentAction {
    case photo, photoFile, file, poll, stickers, spoiler, videoNote, scheduled
}

struct AttachmentMenuView: View {
    let spoilerEnabled: Bool
    var compact = false
    let onSelect: (AttachmentAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Button { select(.photo) } label: {
                    Label("Фото или видео", systemImage: "photo")
                }
                Button { select(.photoFile) } label: {
                    Label("Фото или видео без сжатия", systemImage: "photo.badge.arrow.down")
                }
                Button { select(.file) } label: {
                    Label("Файл", systemImage: "doc")
                }
                if !compact {
                Button { select(.poll) } label: {
                    Label("Опрос", systemImage: "chart.bar")
                }
                Button { select(.stickers) } label: {
                    Label("Стикеры и гифки", systemImage: "face.smiling")
                }
                Button { select(.spoiler) } label: {
                    Label(
                        spoilerEnabled ? "Выключить спойлер" : "Отправить под спойлер",
                        systemImage: spoilerEnabled ? "eye.slash.fill" : "eye.slash"
                    )
                }
                Button { select(.videoNote) } label: {
                    Label("Видеосообщение", systemImage: "video.circle")
                }
                Button { select(.scheduled) } label: {
                    Label("Отложенное сообщение", systemImage: "clock")
                }
                }
            }
            .navigationTitle("Вложение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func select(_ action: AttachmentAction) {
        onSelect(action)
        dismiss()
    }
}
