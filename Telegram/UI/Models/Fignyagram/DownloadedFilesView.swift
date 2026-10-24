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
                        Text(search.isEmpty ? "Скачанных файлов пока нет" : "Ничего не найдено")
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
                                Label("Удалить из памяти", systemImage: "trash")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Скачанные файлы")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Поиск по имени файла")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(files.downloadedFiles.isEmpty)
                    .accessibilityLabel("Очистить кэш файлов")
                }
            }
            .confirmationDialog(
                "Очистить кэш файлов?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Очистить весь кэш", role: .destructive) {
                    TelegramClient.shared.clearFileCache()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все скачанные файлы и миниатюры будут удалены из памяти приложения. Это действие нельзя отменить.")
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
