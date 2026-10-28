import SwiftUI

struct CacheSettingsView: View {
    @ObservedObject private var cache = CacheManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pendingCategory: CacheManager.Category?
    @State private var showClearAll = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Всего в кэше")
                        Spacer()
                        Text(MessageFormatter.fileSize(cache.totalBytes))
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text("Кэш можно очищать по категориям. История сообщений и аккаунт не удаляются.")
                        .font(.appFootnote)
                }

                Section {
                    Picker(NSLocalizedString("Cache.AutoClean", comment: ""), selection: Binding(
                        get: { UserDefaults.standard.integer(forKey: "autoCleanCacheLimitMB") },
                        set: { UserDefaults.standard.set($0, forKey: "autoCleanCacheLimitMB") }
                    )) {
                        Text(NSLocalizedString("Cache.AutoCleanOff", comment: "")).tag(0)
                        Text("500 МБ").tag(500)
                        Text("1 ГБ").tag(1024)
                        Text("2 ГБ").tag(2048)
                        Text("5 ГБ").tag(5120)
                    }
                } footer: {
                    Text("При превышении лимита раз в 10 минут очищаются две самые тяжёлые категории. Сообщения и аккаунт не затрагиваются.")
                        .font(.appFootnote)
                }

                Section("Категории") {
                    ForEach(cache.categories) { category in
                        HStack(spacing: 12) {
                            Image(systemName: category.icon)
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                Text("\(category.count) файлов")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(MessageFormatter.fileSize(category.bytes))
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                            Button {
                                pendingCategory = category
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .disabled(category.bytes == 0 || cache.isWorking)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showClearAll = true
                    } label: {
                        Label("Очистить весь кэш", systemImage: "trash")
                    }
                    .disabled(cache.totalBytes == 0 || cache.isWorking)

                    Button {
                        ImageCache.clear()
                        cache.refresh()
                    } label: {
                        Label("Очистить кэш изображений в памяти", systemImage: "photo.on.rectangle")
                    }

                    Button(role: .destructive) {
                        ChatStore.shared.clearLoadedMessages()
                    } label: {
                        Label("Очистить кэш сообщений", systemImage: "bubble.left.and.bubble.right")
                    }
                } footer: {
                    Text("Очистка кэша сообщений освобождает загруженную историю из памяти. Сами сообщения остаются в Telegram и загрузятся снова при открытии чата.")
                        .font(.appFootnote)
                }
            }
            .navigationTitle("Память и кэш")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task { cache.refresh() }
            .overlay {
                if cache.isWorking {
                    ProgressView("Очистка…")
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .confirmationDialog(
                "Очистить категорию?",
                isPresented: Binding(
                    get: { pendingCategory != nil },
                    set: { if !$0 { pendingCategory = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let category = pendingCategory {
                    Button("Очистить «\(category.title)»", role: .destructive) {
                        cache.clear(category)
                        pendingCategory = nil
                    }
                }
                Button("Отмена", role: .cancel) { pendingCategory = nil }
            }
            .confirmationDialog(
                "Очистить весь кэш?",
                isPresented: $showClearAll,
                titleVisibility: .visible
            ) {
                Button("Очистить всё", role: .destructive) {
                    cache.clearAll()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Будут удалены скачанные медиа, файлы, сохранённые гифки и кэш загруженных сообщений. История в Telegram останется.")
            }
        }
        .navigationViewStyle(.stack)
    }
}
