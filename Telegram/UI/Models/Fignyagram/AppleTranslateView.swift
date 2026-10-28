import SwiftUI
import Translation

/// On-device translation through Apple's Translation framework: no network
/// calls, no third-party API keys, nothing leaves the device.
@available(iOS 18.0, *)
struct AppleTranslateSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var output = ""
    @State private var failed = false
    @State private var configuration = TranslationSession.Configuration(
        source: nil,
        target: Locale.Language(identifier: "ru")
    )

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Auto.34c4df5a64")) {
                    Text(text).textSelection(.enabled)
                }
                Section(L10n.t("Auto.9e7529414c")) {
                    if output.isEmpty && !failed {
                        HStack { ProgressView(); Text(L10n.t("Auto.4801573e67")).foregroundColor(.secondary) }
                    } else if failed {
                        Text(L10n.t("Auto.7e8e59212d"))
                            .foregroundColor(.secondary)
                    } else {
                        Text(output).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(L10n.t("Auto.95ce00afa5"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .translationTask(configuration) { session in
                do {
                    let response = try await session.translate(text)
                    output = response.targetText
                } catch {
                    failed = true
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
