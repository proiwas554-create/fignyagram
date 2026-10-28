import SwiftUI
import TDLibKit

/// All media/files of one chat with category filters.
struct ChatMediaView: View {
    let chatId: Int64
    let onOpen: (Int64) -> Void

    enum Category: String, CaseIterable, Identifiable {
        case media, files, audio, video, voice
        var id: String { rawValue }
        var title: String {
            switch self {
            case .media: return "Медиа"
            case .files: return "Файлы"
            case .audio: return "Аудио"
            case .video: return "Видео"
            case .voice: return "Голосовые"
            }
        }
        var filter: SearchMessagesFilter {
            switch self {
            case .media: return .searchMessagesFilterPhotoAndVideo
            case .files: return .searchMessagesFilterDocument
            case .audio: return .searchMessagesFilterAudio
            case .video: return .searchMessagesFilterVideo
            case .voice: return .searchMessagesFilterVoiceNote
            }
        }
    }

    @ObservedObject private var files = FileStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .media
    @State private var messages: [TDLibKit.Message] = []
    @State private var isLoading = false
    @State private var search = ""

    private var filtered: [TDLibKit.Message] {
        guard !search.isEmpty else { return messages }
        return messages.filter { MessageFormatter.preview($0.content).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Category.allCases) { item in
                            Button {
                                category = item
                                Task { await load() }
                            } label: {
                                Text(item.title)
                                    .font(.appFootnote)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(category == item ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)))
                                    .foregroundColor(category == item ? .accentColor : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if isLoading {
                    Spacer(); ProgressView(); Spacer()
                } else if filtered.isEmpty {
                    Spacer()
                    Text("Ничего не найдено").foregroundColor(.secondary)
                    Spacer()
                } else {
                    List(filtered, id: \.id) { message in
                        Button { onOpen(message.id); dismiss() } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(for: message))
                                    .frame(width: 22)
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(for: message)).lineLimit(1)
                                    Text(MessageFormatter.listDate(message.date))
                                        .font(.appCaption).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $search, prompt: "Поиск по названию")
            .navigationTitle("Медиа и файлы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .task { await load() }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        isLoading = true
        messages = await TelegramClient.shared.chatMediaMessages(chatId: chatId, filter: category.filter)
        isLoading = false
    }

    private func title(for message: TDLibKit.Message) -> String {
        switch message.content {
        case .messagePhoto: return "Фото"
        case .messageVideo(let v): return v.video.fileName.isEmpty ? "Видео" : v.video.fileName
        case .messageDocument(let d): return d.document.fileName.isEmpty ? "Документ" : d.document.fileName
        case .messageAudio(let a): return a.audio.title.isEmpty ? a.audio.fileName : a.audio.title
        case .messageVoiceNote: return "Голосовое сообщение"
        default: return MessageFormatter.preview(message.content)
        }
    }

    private func icon(for message: TDLibKit.Message) -> String {
        switch message.content {
        case .messagePhoto: return "photo"
        case .messageVideo: return "video"
        case .messageAudio: return "music.note"
        case .messageVoiceNote: return "waveform"
        case .messageDocument: return "doc"
        default: return "paperclip"
        }
    }
}
