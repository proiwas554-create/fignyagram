import SwiftUI

enum CreateChatKind: String, Identifiable {
    case channel, group
    var id: String { rawValue }
    var title: String { self == .channel ? "Новый канал" : "Новая группа" }
    var isChannel: Bool { self == .channel }
}

/// Create a channel or a group with a title and description.
struct CreateChatView: View {
    let kind: CreateChatKind
    let onCreated: (Int64) -> Void

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var username = ""
    @State private var isPublic = false
    @State private var isCreating = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(kind == .channel ? "Название канала" : "Название группы", text: $title)
                    TextField(L10n.t("Auto.38ca0af80c"), text: $description)
                    Toggle(kind == .channel ? "Публичный канал" : "Публичная группа", isOn: $isPublic)
                    if isPublic {
                        HStack {
                            Text("@").foregroundColor(.secondary)
                            TextField("username", text: $username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                } footer: {
                    Text(kind == .channel
                         ? "Канал создаётся сразу; юзернейм можно задать позже в профиле."
                         : "Группа создаётся и открывается сразу после создания.")
                        .font(.appFootnote)
                }
            }
            .navigationTitle(kind.title)
            .modifier(GlassListModifier())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Auto.b059f7e15d")) { create() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func create() {
        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let cleanTitle = title.trimmingCharacters(in: .whitespaces)
                let chatId = try await client.createChannelOrGroup(
                    title: cleanTitle,
                    description: description,
                    isChannel: kind.isChannel
                )
                let cleanUsername = username.trimmingCharacters(in: .whitespaces)
                if (isPublic && !cleanUsername.isEmpty) || !description.isEmpty {
                    try? await client.updateChatProfile(
                        chatId: chatId,
                        title: cleanTitle,
                        description: description,
                        username: isPublic && !cleanUsername.isEmpty ? cleanUsername : nil,
                        photo: nil
                    )
                }
                onCreated(chatId)
                dismiss()
            } catch {
                client.errorMessage = TelegramClient.describe(error)
            }
        }
    }
}
