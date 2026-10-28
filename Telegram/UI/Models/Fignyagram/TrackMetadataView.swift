import SwiftUI
import UIKit

struct TrackMetadataView: View {
    let track: MusicTrack

    @ObservedObject private var library = MusicLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var newArtwork: UIImage?
    @State private var removeArtwork = false
    @State private var showPhotoPicker = false

    init(track: MusicTrack) {
        self.track = track
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        if let newArtwork {
                            Image(uiImage: newArtwork)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else if let url = library.artworkURL(for: track),
                                  let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            MusicArtworkView(track: track, size: 80)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Button("Выбрать обложку") {
                                removeArtwork = false
                                showPhotoPicker = true
                            }
                            if library.artworkURL(for: track) != nil || newArtwork != nil {
                                Button("Удалить обложку", role: .destructive) {
                                    newArtwork = nil
                                    removeArtwork = true
                                }
                            }
                        }
                    }
                }

                Section("Название") {
                    TextField("Название трека", text: $title)
                }

                Section("Исполнитель") {
                    TextField("Имя автора", text: $artist)
                }
            }
            .navigationTitle("Редактировать трек")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Save")) {
                        library.updateMetadata(
                            track,
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                            artwork: newArtwork,
                            removeArtwork: removeArtwork
                        )
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { providers in
                    guard let provider = providers.first else { return }
                    Task {
                        if let image = await MediaPreparer.loadImage(provider) {
                            newArtwork = image
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .navigationViewStyle(.stack)
    }
}
