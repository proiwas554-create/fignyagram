import SwiftUI

struct MemberTagView: View {
    let chatId: Int64
    let userId: Int64

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tag = ""
    @State private var isLoading = true
    @State private var isSaving = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Тег (до 16 символов)", text: $tag)
                } footer: {
                    Text("Тег виден рядом с именем участника в этом чате. Для выдачи тега нужны права администратора с разрешением на управление тегами.")
                        .font(.appFootnote)
                }
                if isLoading { Section { ProgressView() } }
            }
            .navigationTitle("Тег участника")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("Common.Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Save")) {
                        isSaving = true
                        Task {
                            do {
                                try await client.setMemberTag(chatId: chatId, userId: userId, tag: tag)
                                dismiss()
                            } catch {
                                client.errorMessage = TelegramClient.describe(error)
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isLoading || isSaving || tag.count > 16)
                }
            }
            .task {
                tag = await client.memberTag(chatId: chatId, userId: userId) ?? ""
                isLoading = false
            }
        }
        .navigationViewStyle(.stack)
    }
}
