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
                        Button("Изменить фото") { showPhotoPicker = true }
                    }
                }

                Section("Название") {
                    TextField("Название канала или группы", text: $title)
                }

                Section("Описание") {
                    ZStack(alignment: .topLeading) {
                        if description.isEmpty {
                            Text("Описание")
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
                        Text("Публичная ссылка")
                    } footer: {
                        Text("Можно оставить пустым, чтобы убрать публичный username.")
                            .font(.appFootnote)
                    }
                }
            }
            .navigationTitle("Редактировать")
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
