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
            let wantsClear = containsAny(text, ["очист", "почист", "удал", "освобод", "сброс"])
            let wantsMemory = containsAny(text, ["кэш", "памят", "мусор", "данн"])
            let wantsInvisible = containsAny(text, ["невидим", "скрыт", "невидимк", "призрак"])
            let wantsDeleted = containsAny(text, ["удалён", "удален", "удаленные", "удалённые"])
            let wantsStatus = containsAny(text, ["статус", "состоян", "что включ", "что там", "покажи"])
            let enable = containsAny(text, ["включ", "вруб", "активир", "поставь", "разреши"])
            let disable = containsAny(text, ["выключ", "отключ", "выруб", "убери", "запрет"])

            if wantsClear && wantsMemory {
                cache.clearAll()
                lastTopic = .cache
                result = "Кэш очищается."
            } else if wantsDeleted {
                let value = disable ? false : (enable ? true : !privacy.keepDeletedMessages)
                privacy.keepDeletedMessages = value
                lastTopic = .deleted
                result = value ? "Показ удалённых сообщений включён." : "Показ удалённых сообщений выключен."
            } else if wantsStatus {
                let invisible = await client.isInvisibleMode()
                lastTopic = .status
                result = "Невидимка: \(invisible ? "включена" : "выключена"). Удалённые: \(privacy.keepDeletedMessages ? "показываются" : "скрываются"). Кэш: \(MessageFormatter.fileSize(cache.totalBytes))."
            } else if wantsInvisible {
                let value = disable ? false : (enable ? true : true)
                do {
                    try await client.setInvisibleMode(value)
                    lastTopic = .invisible
                    result = value ? "Режим невидимки включён." : "Режим невидимки выключен."
                } catch {
                    result = TelegramClient.describe(error)
                }
            } else if enable || disable {
                switch lastTopic {
                case .invisible:
                    do {
                        try await client.setInvisibleMode(enable)
                        result = enable ? "Режим невидимки включён." : "Режим невидимки выключен."
                    } catch { result = TelegramClient.describe(error) }
                case .deleted:
                    privacy.keepDeletedMessages = enable
                    result = enable ? "Показ удалённых включён." : "Показ удалённых выключен."
                case .cache:
                    cache.clearAll()
                    result = "Кэш очищается."
                default:
                    result = "Уточните: невидимка, удалённые или кэш."
                }
            } else if containsAny(text, ["помощь", "help", "что умеешь", "команд"]) {
                result = "Можно: «почисти память», «статус», «сделай меня невидимым», «пусть удалённые остаются», затем просто «включи» или «выключи»."
            } else {
                result = "Не понял. Попробуйте: «почисти кэш», «статус», «включи невидимку»."
            }
        }
    }
}
