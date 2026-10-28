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
                Section("Оригинал") {
                    Text(text).textSelection(.enabled)
                }
                Section("Перевод") {
                    if let result {
                        Text(result).textSelection(.enabled)
                    } else if let errorText {
                        Text(errorText).foregroundColor(.secondary)
                    } else {
                        ProgressView("Перевод…")
                    }
                }
            }
            .navigationTitle("Перевод")
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
