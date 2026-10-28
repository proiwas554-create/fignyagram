import SwiftUI
import TDLibKit

struct ProfileMusicView: View {
    let userId: Int64
    let title: String

    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var library = MusicLibrary.shared
    @ObservedObject private var player = MusicPlayer.shared
    @Environment(\.dismiss) private var dismiss

    @State private var audios: [TDLibKit.Audio] = []
    @State private var isLoading = true
    @State private var loadingAudioID: Int?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView(NSLocalizedString("Generated.acf22311865d", comment: ""))
                } else if audios.isEmpty {
                    Text(L10n.t("Auto.187ec31e72"))
                        .foregroundColor(.secondary)
                } else {
                    List(audios, id: \.audio.id) { audio in
                        HStack(spacing: 10) {
                            ProfileAudioArtwork(audio: audio, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(audio.title.isEmpty ? audio.fileName : audio.title)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text(audio.performer.isEmpty ? NSLocalizedString("Generated.2ec7208d11d8", comment: "") : audio.performer)
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                guard loadingAudioID == nil else { return }
                                loadingAudioID = audio.audio.id
                                Task {
                                    defer { loadingAudioID = nil }
                                    if let track = await library.ensureImported(audio: audio) {
                                        player.play(track, queue: library.tracks)
                                    }
                                }
                            } label: {
                                if loadingAudioID == audio.audio.id {
                                    ProgressView()
                                } else {
                                    Image(systemName: "play.circle")
                                        .font(.system(size: 22))
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(loadingAudioID != nil)
                            Button {
                                Task { await library.importProfileAudios([audio]) }
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 22))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .task {
                audios = await client.profileAudios(userId: userId)
                isLoading = false
            }
        }
        .navigationViewStyle(.stack)
    }
}
