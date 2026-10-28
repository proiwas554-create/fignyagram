import SwiftUI

struct PerformanceSettingsView: View {
    @ObservedObject private var performance = PerformanceMode.shared
    @ObservedObject private var limits = DisplayLimits.shared
    @ObservedObject private var ultra = UltraMode.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle(L10n.t("Auto.cd9fd52e97"), isOn: Binding(
                        get: { ultra.isEnabled },
                        set: { ultra.setEnabled($0) }
                    ))
                } header: {
                    Text(L10n.t("Auto.35ed94d179"))
                } footer: {
                    Text(L10n.t("Auto.87770be0e8"))
                        .font(.appFootnote)
                }

                Section {
                    Toggle(L10n.t("Auto.707bd05a2d"), isOn: $performance.isEnabled)
                } footer: {
                    Text(L10n.t("Auto.e77ab56b9b"))
                        .font(.appFootnote)
                }

                if performance.isEnabled {
                    Section(L10n.t("Auto.c09fb627f9")) {
                        Picker(L10n.t("Auto.6e1572de13"), selection: $performance.level) {
                            ForEach(PerformanceLevel.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section(L10n.t("Auto.2cbb35de48")) {
                    Label(L10n.t("Auto.d51dc53ea8"), systemImage: "photo")
                    Label("Кэш изображений до \(performance.level.cacheLimit / (1024 * 1024)) МБ", systemImage: "internaldrive")
                    Label("Фото декодируются с разрешением до \(Int(performance.level.maxPixel)) px", systemImage: "arrow.down.right.and.arrow.up.left")
                    Label("До \(limits.effectiveMessagesPerChat) сообщений в чате вместо \(limits.maxMessagesPerChat)", systemImage: "bubble.left.and.bubble.right")
                    Label("До \(limits.effectiveRenderedChats) чатов в списке вместо \(limits.maxRenderedChats)", systemImage: "list.bullet")
                }

                Section {
                    Button(L10n.t("Auto.5b898b4bb0")) {
                        ImageCache.clear()
                    }
                } footer: {
                    Text(L10n.t("Auto.8b480c6ab4"))
                        .font(.appFootnote)
                }
            }
            .navigationTitle(L10n.t("Auto.c09fb8d62b"))
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
