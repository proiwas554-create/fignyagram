import SwiftUI

struct TranslationResultView: View {
    let original: String
    let translated: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Auto.34c4df5a64")) {
                    Text(original).textSelection(.enabled)
                }
                Section(L10n.t("Auto.b93e8b66b6")) {
                    Text(translated).textSelection(.enabled)
                }
            }
            .navigationTitle(L10n.t("Auto.b93e8b66b6"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
