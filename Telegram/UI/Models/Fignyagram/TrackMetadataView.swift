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
                            Button(L10n.t("Auto.22074ce35a")) {
                                removeArtwork = false
                                showPhotoPicker = true
                            }
                            if library.artworkURL(for: track) != nil || newArtwork != nil {
                                Button(L10n.t("Auto.7a7a3f51ae"), role: .destructive) {
                                    newArtwork = nil
                                    removeArtwork = true
                                }
                            }
                        }
                    }
                }

                Section(L10n.t("Auto.602680ed89")) {
                    TextField(L10n.t("Auto.7a08bd376b"), text: $title)
                }

                Section(L10n.t("Auto.1d3ab78a9a")) {
                    TextField(L10n.t("Auto.cd7a9cf4fa"), text: $artist)
                }
            }
            .navigationTitle(L10n.t("Auto.9fa697c59b"))
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
