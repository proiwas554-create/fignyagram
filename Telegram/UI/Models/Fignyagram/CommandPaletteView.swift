import SwiftUI

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var privacy = PrivacyPreferences.shared

    @State private var command = ""
    @State private var result = ""
    @State private var isWorking = false
    private enum Topic { case cache, invisible, deleted, status }
    @State private var lastTopic: Topic?

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.t("Auto.e4a32a17fc")).font(.appHeadline)

                TextField(L10n.t("Auto.87b4c83b5f"), text: $command)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Button {
                    execute()
                } label: {
                    Label(L10n.t("Auto.bdf82a2a10"), systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)

                if isWorking { ProgressView() }

                if !result.isEmpty {
                    Text(result)
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(L10n.t("Auto.df07d75a54"))
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(18)
            .navigationTitle(L10n.t("Auto.ce87c3f7c4"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func containsAny(_ text: String, _ stems: [String]) -> Bool {
        stems.contains { text.contains($0) }
    }

    private func execute() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isWorking = true
        result = ""
        Task {
            defer { isWorking = false }
            let wantsClear = containsAny(text, [NSLocalizedString("Generated.3b7ec5a17b67", comment: ""), NSLocalizedString("Generated.11ddfef408f1", comment: ""), NSLocalizedString("Generated.a5626cccd891", comment: ""), NSLocalizedString("Generated.7f8a49adb553", comment: ""), NSLocalizedString("Generated.a487eb69ba59", comment: "")])
            let wantsMemory = containsAny(text, [NSLocalizedString("Generated.611cdeb92886", comment: ""), NSLocalizedString("Generated.0dedddac1311", comment: ""), NSLocalizedString("Generated.8c1b60b1199b", comment: ""), NSLocalizedString("Generated.c4cbdcc9ef32", comment: "")])
            let wantsInvisible = containsAny(text, [NSLocalizedString("Generated.2ac65121a3c4", comment: ""), NSLocalizedString("Generated.32956e1594e9", comment: ""), NSLocalizedString("Generated.e7e4274a6726", comment: ""), NSLocalizedString("Generated.6c5f535e6aa2", comment: "")])
            let wantsDeleted = containsAny(text, [NSLocalizedString("Generated.7fa4077770da", comment: ""), NSLocalizedString("Generated.44204d8f15b5", comment: ""), NSLocalizedString("Generated.7a4c7257958e", comment: ""), NSLocalizedString("Generated.1a331e640579", comment: "")])
            let wantsStatus = containsAny(text, [NSLocalizedString("Generated.7fed085d2147", comment: ""), NSLocalizedString("Generated.b1d7374f777d", comment: ""), NSLocalizedString("Generated.1bb433d1dca5", comment: ""), NSLocalizedString("Generated.8340d3b8ff86", comment: ""), NSLocalizedString("Generated.d72a54d2b889", comment: "")])
            let enable = containsAny(text, [NSLocalizedString("Generated.5cbcd8b03c75", comment: ""), NSLocalizedString("Generated.047d61bd86e9", comment: ""), NSLocalizedString("Generated.4e4f52371543", comment: ""), NSLocalizedString("Generated.be0a544c98da", comment: ""), NSLocalizedString("Generated.2c3456ac659d", comment: "")])
            let disable = containsAny(text, [NSLocalizedString("Generated.d74c8612f803", comment: ""), NSLocalizedString("Generated.8332f174851f", comment: ""), NSLocalizedString("Generated.57982a102305", comment: ""), NSLocalizedString("Generated.98943f0ea183", comment: ""), NSLocalizedString("Generated.4217b2c13cfa", comment: "")])

            if wantsClear && wantsMemory {
                cache.clearAll()
                lastTopic = .cache
                result = NSLocalizedString("Generated.3dc62a6399d3", comment: "")
            } else if wantsDeleted {
                let value = disable ? false : (enable ? true : !privacy.keepDeletedMessages)
                privacy.keepDeletedMessages = value
                lastTopic = .deleted
                result = value ? NSLocalizedString("Generated.712dd7737662", comment: "") : NSLocalizedString("Generated.d0fffb7eac13", comment: "")
            } else if wantsStatus {
                let invisible = await client.isInvisibleMode()
                lastTopic = .status
                result = "Невидимка: \(invisible ? "включена" : "выключена"). Удалённые: \(privacy.keepDeletedMessages ? "показываются" : "скрываются"). Кэш: \(MessageFormatter.fileSize(cache.totalBytes))."
            } else if wantsInvisible {
                let value = disable ? false : (enable ? true : true)
                do {
                    try await client.setInvisibleMode(value)
                    lastTopic = .invisible
                    result = value ? NSLocalizedString("Generated.bc00924ee917", comment: "") : NSLocalizedString("Generated.a447a932fa18", comment: "")
                } catch {
                    result = TelegramClient.describe(error)
                }
            } else if enable || disable {
                switch lastTopic {
                case .invisible:
                    do {
                        try await client.setInvisibleMode(enable)
                        result = enable ? NSLocalizedString("Generated.bc00924ee917", comment: "") : NSLocalizedString("Generated.a447a932fa18", comment: "")
                    } catch { result = TelegramClient.describe(error) }
                case .deleted:
                    privacy.keepDeletedMessages = enable
                    result = enable ? NSLocalizedString("Generated.b5c49ce5c102", comment: "") : NSLocalizedString("Generated.b2d33ebf0b8b", comment: "")
                case .cache:
                    cache.clearAll()
                    result = NSLocalizedString("Generated.3dc62a6399d3", comment: "")
                default:
                    result = NSLocalizedString("Generated.0af3c23329e4", comment: "")
                }
            } else if containsAny(text, [NSLocalizedString("Generated.50b230fe07bc", comment: ""), "help", NSLocalizedString("Generated.3f4ae9e96b07", comment: ""), NSLocalizedString("Generated.f53aab4c7690", comment: "")]) {
                result = NSLocalizedString("Generated.89db1a211e71", comment: "")
            } else {
                result = NSLocalizedString("Generated.5c90ed9795df", comment: "")
            }
        }
    }
}
