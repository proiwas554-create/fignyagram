import SwiftUI
import UIKit
import TDLibKit

struct ChannelEditorView: View {
    let chatId: Int64
    let initialTitle: String
    let initialDescription: String
    let initialUsername: String?
    let initialPhoto: ChatPhotoInfo?

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var description: String
    @State private var username: String
    @State private var newPhoto: UIImage?
    @State private var showPhotoPicker = false
    @State private var isSaving = false

    init(
        chatId: Int64,
        initialTitle: String,
        initialDescription: String,
        initialUsername: String?,
        initialPhoto: ChatPhotoInfo?
    ) {
        self.chatId = chatId
        self.initialTitle = initialTitle
        self.initialDescription = initialDescription
        self.initialUsername = initialUsername
        self.initialPhoto = initialPhoto
        _title = State(initialValue: initialTitle)
        _description = State(initialValue: initialDescription)
        _username = State(initialValue: initialUsername ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        if let newPhoto {
                            Image(uiImage: newPhoto)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                        } else {
                            AvatarView(
                                id: chatId,
                                title: initialTitle,
                                photo: initialPhoto,
                                size: 72
                            )
                        }
                        Button(L10n.t("Auto.775d9c0733")) { showPhotoPicker = true }
                    }
                }

                Section(L10n.t("Auto.602680ed89")) {
                    TextField(L10n.t("Auto.a020d97275"), text: $title)
                }

                Section(L10n.t("Auto.38ca0af80c")) {
                    ZStack(alignment: .topLeading) {
                        if description.isEmpty {
                            Text(L10n.t("Auto.38ca0af80c"))
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                        TextEditor(text: $description)
                            .frame(minHeight: 120)
                    }
                }

                if initialUsername != nil {
                    Section {
                        HStack(spacing: 2) {
                            Text("@").foregroundColor(.secondary)
                            TextField("username", text: $username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } header: {
                        Text(L10n.t("Auto.18f9b51832"))
                    } footer: {
                        Text(L10n.t("Auto.f220aa2be6"))
                            .font(.appFootnote)
                    }
                }
            }
            .navigationTitle(L10n.t("Auto.1706282c52"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Save")) { save() }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { providers in
                    guard let provider = providers.first else { return }
                    Task {
                        if let image = await MediaPreparer.loadImage(provider) {
                            newPhoto = image
                        }
                    }
                }
                .ignoresSafeArea()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        isSaving = true
        Task {
            do {
                try await client.updateChatProfile(
                    chatId: chatId,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description,
                    username: initialUsername == nil ? nil : username.trimmingCharacters(in: .whitespacesAndNewlines),
                    photo: newPhoto
                )
                dismiss()
            } catch {
                client.errorMessage = TelegramClient.describe(error)
            }
            isSaving = false
        }
    }
}
