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
                    Label(L10n.t("Auto.fad652fe0a"), systemImage: "photo")
                }
                Button { select(.photoFile) } label: {
                    Label(L10n.t("Auto.e9b338a0c3"), systemImage: "photo.badge.arrow.down")
                }
                Button { select(.file) } label: {
                    Label(L10n.t("Auto.2d46f36e5b"), systemImage: "doc")
                }
                if !compact {
                Button { select(.poll) } label: {
                    Label(L10n.t("Auto.9f36f74f52"), systemImage: "chart.bar")
                }
                Button { select(.stickers) } label: {
                    Label(L10n.t("Auto.301763c9c8"), systemImage: "face.smiling")
                }
                Button { select(.spoiler) } label: {
                    Label(
                        spoilerEnabled ? NSLocalizedString("Generated.21d26c5d86e4", comment: "") : NSLocalizedString("Generated.3d325a0da30f", comment: ""),
                        systemImage: spoilerEnabled ? "eye.slash.fill" : "eye.slash"
                    )
                }
                Button { select(.videoNote) } label: {
                    Label(L10n.t("Auto.2951438978"), systemImage: "video.circle")
                }
                Button { select(.scheduled) } label: {
                    Label(L10n.t("Auto.ed61a83aab"), systemImage: "clock")
                }
                }
            }
            .navigationTitle(L10n.t("Auto.ef44209446"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
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
