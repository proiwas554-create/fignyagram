import SwiftUI
import AVFoundation
import UIKit

struct ShareComposerView: View {
    let payload: SharedPayload

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var files: [URL]
    @State private var fileNames: [String]
    @State private var showChatPicker = false

    init(payload: SharedPayload) {
        self.payload = payload
        _text = State(initialValue: payload.combinedText)
        _files = State(initialValue: payload.files)
        _fileNames = State(initialValue: payload.files.map { $0.lastPathComponent })
    }

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Auto.8c45d9cf57")) {
                    TextEditor(text: $text).frame(minHeight: 100)
                }
                if !files.isEmpty {
                    Section(L10n.t("Auto.200cd7baf7")) {
                        ForEach(files.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Image(systemName: icon(for: files[index]))
                                    TextField(L10n.t("Auto.1aa39e331d"), text: $fileNames[index])
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                    Button(role: .destructive) {
                                        files.remove(at: index)
                                        fileNames.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                                Text(MessageFormatter.fileSize(Int64((try? files[index].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)))
                                    .font(.appCaption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button { showChatPicker = true } label: {
                        Label(L10n.t("Auto.724d5961a1"), systemImage: "paperplane")
                    }
                }
            }
            .navigationTitle(L10n.t("Auto.29eeabd94c"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
            }
            .sheet(isPresented: $showChatPicker) {
                ChatPickerView(title: "Отправить в…") { chatId in
                    send(to: chatId)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func send(to chatId: Int64) {
        let trimmedCaption = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if files.isEmpty && !trimmedCaption.isEmpty {
            client.sendText(text, to: chatId)
        }
        for index in files.indices {
            let caption = index == 0 ? trimmedCaption : ""
            let url = renamedFile(files[index], desiredName: fileNames[index])
            if let image = UIImage(contentsOfFile: url.path) {
                client.sendPhoto(url, width: Int(image.size.width), height: Int(image.size.height), caption: caption, to: chatId, replyTo: nil)
            } else if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
                let asset = AVURLAsset(url: url)
                let duration = Int(CMTimeGetSeconds(asset.duration))
                client.sendVideo(url, width: 0, height: 0, duration: duration, caption: caption, to: chatId, replyTo: nil)
            } else {
                client.sendDocument(url, caption: caption, to: chatId, replyTo: nil)
            }
        }
        for url in files { try? FileManager.default.removeItem(at: url) }
        ShareInbox.shared.consume()
        dismiss()
    }

    private func renamedFile(_ source: URL, desiredName: String) -> URL {
        let trimmed = desiredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = source.lastPathComponent
        var name = trimmed.isEmpty ? fallback : trimmed
        if URL(fileURLWithPath: name).pathExtension.isEmpty, !source.pathExtension.isEmpty {
            name += "." + source.pathExtension
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "webp": return "photo"
        case "mp4", "mov", "m4v": return "video"
        default: return "doc"
        }
    }
}
