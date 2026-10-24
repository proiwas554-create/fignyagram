import SwiftUI

struct TranslationResultView: View {
    let original: String
    let translated: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Оригинал") {
                    Text(original).textSelection(.enabled)
                }
                Section("Перевод") {
                    Text(translated).textSelection(.enabled)
                }
            }
            .navigationTitle("Перевод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
