import SwiftUI

struct TranslationSheet: View {
    let text: String

    @ObservedObject private var translation = TranslationService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Auto.34c4df5a64")) {
                    Text(text).textSelection(.enabled)
                }
                Section(L10n.t("Auto.b93e8b66b6")) {
                    if let result {
                        Text(result).textSelection(.enabled)
                    } else if let errorText {
                        Text(errorText).foregroundColor(.secondary)
                    } else {
                        ProgressView("Перевод…")
                    }
                }
            }
            .navigationTitle(L10n.t("Auto.b93e8b66b6"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .task {
                if let translated = await translation.translate(text) {
                    result = translated
                } else {
                    errorText = "Не удалось перевести текст"
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
