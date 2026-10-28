import SwiftUI
import TDLibKit

struct DownloadedFilesView: View {
    @ObservedObject private var files = FileStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var selectedFile: SelectedDownload?
    @State private var showClearConfirmation = false

    private var displayed: [TDLibKit.File] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = files.downloadedFiles
        guard !query.isEmpty else { return all }
        return all.filter {
            URL(fileURLWithPath: $0.local.path).lastPathComponent
                .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            Group {
                if displayed.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(search.isEmpty ? NSLocalizedString("Generated.5c3082ab52a7", comment: "") : NSLocalizedString("Generated.dcd57a91d647", comment: ""))
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(displayed, id: \.id) { file in
                        Button {
                            selectedFile = SelectedDownload(
                                url: URL(fileURLWithPath: file.local.path)
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: file))
                                    .font(.appTitle3)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: file.local.path).lastPathComponent)
                                        .font(.appSubheadline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(MessageFormatter.fileSize(max(file.size, file.expectedSize)))
                                        .font(.appCaption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                TelegramClient.shared.deleteDownloadedFile(file)
                            } label: {
                                Label(L10n.t("Auto.3eab6a0974"), systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.t("Auto.c2f7359a1b"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: NSLocalizedString("Generated.d1617a222cf2", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(files.downloadedFiles.isEmpty)
                    .accessibilityLabel(L10n.t("Auto.f406b7a85e"))
                }
            }
            .confirmationDialog(L10n.t("Auto.baaebec86a"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.t("Auto.610bc3b777"), role: .destructive) {
                    TelegramClient.shared.clearFileCache()
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t("Auto.3f42ebe614"))
            }
            .sheet(item: $selectedFile) { item in
                QuickLookView(url: item.url)
                    .ignoresSafeArea()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func icon(for file: TDLibKit.File) -> String {
        let ext = URL(fileURLWithPath: file.local.path).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "webp", "gif": return "photo"
        case "mp4", "mov", "m4v": return "video"
        case "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z": return "archivebox"
        default: return "doc"
        }
    }
}

private struct SelectedDownload: Identifiable {
    let id = UUID()
    let url: URL
}
