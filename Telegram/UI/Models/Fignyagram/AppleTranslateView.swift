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
                Section("Оригинал") {
                    Text(text).textSelection(.enabled)
                }
                Section("Перевод (на устройстве)") {
                    if output.isEmpty && !failed {
                        HStack { ProgressView(); Text("Перевод…").foregroundColor(.secondary) }
                    } else if failed {
                        Text("Не удалось перевести: языковая пара не поддерживается на этом устройстве.")
                            .foregroundColor(.secondary)
                    } else {
                        Text(output).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Перевод Apple")
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
