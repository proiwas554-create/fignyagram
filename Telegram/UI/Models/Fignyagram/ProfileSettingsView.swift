import SwiftUI
import UIKit
import UIKit
import TDLibKit

struct ProfileSettingsView: View {
    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var bio = ""
    @State private var username = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isInvisible = false
    @State private var isPrivacyBusy = false
    @State private var showPhotoPicker = false
    @State private var showPhoneNotice = false
    @State private var loaded = false

    private var profilePhotoInfo: ChatPhotoInfo? {
        guard let photo = client.me?.profilePhoto else { return nil }
        return ChatPhotoInfo(
            big: photo.big,
            hasAnimation: photo.hasAnimation,
            isPersonal: photo.isPersonal,
            minithumbnail: photo.minithumbnail,
            small: photo.small
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AvatarView(
                            id: client.me?.id ?? 0,
                            title: [client.me?.firstName, client.me?.lastName].compactMap { $0 }.joined(separator: " "),
                            photo: profilePhotoInfo,
                            size: 76
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Изменить фото") { showPhotoPicker = true }
                            if profilePhotoInfo != nil {
                                Button("Удалить фото", role: .destructive) {
                                    Task {
                                        do { try await client.removeProfilePhoto() }
                                        catch { client.errorMessage = TelegramClient.describe(error) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if let phone = client.me?.phoneNumber, !phone.isEmpty {
                        HStack {
                            Text("Номер телефона")
                            Spacer()
                            Text("+\(phone)").foregroundColor(.secondary)
                            Button {
                                UIPasteboard.general.string = "+\(phone)"
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Скопировать номер телефона")
                        }
                        Button("Сменить номер") { showPhoneNotice = true }
                    }
                } header: {
                    Text("Аккаунт")
                }

                Section("Имя") {
                    TextField("Имя", text: $firstName)
                        .textContentType(.givenName)
                    TextField("Фамилия", text: $lastName)
                        .textContentType(.familyName)
                }

                Section("О себе") {
                    ZStack(alignment: .topLeading) {
                        if bio.isEmpty {
                            Text("Bio")
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                        TextEditor(text: $bio)
                            .frame(minHeight: 80)
                    }
                }

                Section {
                    HStack(spacing: 2) {
                        Text("@").foregroundColor(.secondary)
                        TextField("username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if !username.isEmpty {
                        Button {
                            UIPasteboard.general.string = "@\(username)"
                        } label: {
                            Label("Копировать @username", systemImage: "doc.on.doc")
                        }
                        .font(.appFootnote)
                    }
                } header: {
                    Text("Юзернейм")
                } footer: {
                    Text("Публичная ссылка вида t.me/username. Можно оставить пустым.")
                        .font(.appFootnote)
                }

                if isLoading {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }
            }
            .navigationTitle(L10n.t("Common.Profile"))
            .modifier(GlassListModifier())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Save")) { save() }
                        .disabled(isSaving || isLoading)
                }
            }
            .task { await load() }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoPicker { providers in
                    guard let provider = providers.first else { return }
                    Task { await updatePhoto(provider) }
                }
                .ignoresSafeArea()
            }
            .confirmationDialog("Смена номера телефона", isPresented: $showPhoneNotice, titleVisibility: .visible) {
                Button("Выйти и войти с другим номером", role: .destructive) {
                    client.logOut()
                    dismiss()
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text("Установленная версия TDLib не поддерживает смену номера без повторной авторизации. Можно выйти из аккаунта и войти заново с новым номером.")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        _ = try? await TelegramClient.shared.refreshMe()
        firstName = client.me?.firstName ?? ""
        lastName = client.me?.lastName ?? ""
        username = client.me?.usernames?.activeUsernames.first ?? client.me?.usernames?.editableUsername ?? ""
        bio = await client.currentBio()
        isInvisible = UserDefaults.standard.bool(forKey: "invisibleModePersistent")
        isLoading = false
    }

    private func save() {
        isSaving = true
        Task {
            do {
                let wasInvisible = isInvisible
                try await client.updateProfile(
                    firstName: firstName.trimmingCharacters(in: .whitespacesAndNewlines),
                    lastName: lastName.trimmingCharacters(in: .whitespacesAndNewlines),
                    bio: bio,
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                if wasInvisible {
                    try? await client.setInvisibleMode(true)
                }
                dismiss()
            } catch {
                client.errorMessage = TelegramClient.describe(error)
            }
            isSaving = false
        }
    }

    private func updatePhoto(_ provider: NSItemProvider) async {
        isSaving = true
        defer { isSaving = false }
        guard let image = await MediaPreparer.loadImage(provider),
              let photo = MediaPreparer.photo(image) else {
            client.errorMessage = "Не удалось подготовить фото"
            return
        }
        do {
            try await client.updateProfilePhoto(photo.url)
        } catch {
            client.errorMessage = TelegramClient.describe(error)
        }
    }
}
