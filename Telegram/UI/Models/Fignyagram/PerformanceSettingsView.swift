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
                    Toggle("Ультра-оптимизация", isOn: Binding(
                        get: { ultra.isEnabled },
                        set: { ultra.setEnabled($0) }
                    ))
                } header: {
                    Text("Ультра-режим")
                } footer: {
                    Text("Оставляет чаты, отправку сообщений, прокси и музыкальный плеер. Скрывает вложения, поиск по лишним разделам, теги, реакции и украшения, уменьшает кэш и количество отрисовываемых сообщений.")
                        .font(.appFootnote)
                }

                Section {
                    Toggle("Режим оптимизации", isOn: $performance.isEnabled)
                } footer: {
                    Text("Уменьшает кэш и качество декодирования изображений, а также временно ограничивает количество отрисовываемых сообщений и чатов. Полезно для экономии батареи и памяти.")
                        .font(.appFootnote)
                }

                if performance.isEnabled {
                    Section("Степень оптимизации") {
                        Picker("Степень", selection: $performance.level) {
                            ForEach(PerformanceLevel.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Что меняется") {
                    Label("Меньше одновременных декодирований изображений", systemImage: "photo")
                    Label("Кэш изображений до \(performance.level.cacheLimit / (1024 * 1024)) МБ", systemImage: "internaldrive")
                    Label("Фото декодируются с разрешением до \(Int(performance.level.maxPixel)) px", systemImage: "arrow.down.right.and.arrow.up.left")
                    Label("До \(limits.effectiveMessagesPerChat) сообщений в чате вместо \(limits.maxMessagesPerChat)", systemImage: "bubble.left.and.bubble.right")
                    Label("До \(limits.effectiveRenderedChats) чатов в списке вместо \(limits.maxRenderedChats)", systemImage: "list.bullet")
                }

                Section {
                    Button("Очистить кэш изображений") {
                        ImageCache.clear()
                    }
                } footer: {
                    Text("Изображения загрузятся заново при следующем открытии.")
                        .font(.appFootnote)
                }
            }
            .navigationTitle("Оптимизация")
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
