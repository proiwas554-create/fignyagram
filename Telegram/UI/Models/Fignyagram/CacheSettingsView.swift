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
                        Text(L10n.t("Cache.Total"))
                        Spacer()
                        Text(MessageFormatter.fileSize(cache.totalBytes))
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    Text(L10n.t("Cache.CategoriesHint"))
                        .font(.appFootnote)
                }

                Section {
                    Picker(L10n.t("Cache.AutoClean"), selection: Binding(
                        get: { UserDefaults.standard.integer(forKey: "autoCleanCacheLimitMB") },
                        set: { UserDefaults.standard.set($0, forKey: "autoCleanCacheLimitMB") }
                    )) {
                        Text(L10n.t("Cache.AutoCleanOff")).tag(0)
                        Text(L10n.t("Auto.3523187d5b")).tag(500)
                        Text(L10n.t("Auto.b4efb1d1ec")).tag(1024)
                        Text(L10n.t("Auto.8969312952")).tag(2048)
                        Text(L10n.t("Auto.b3c62d8079")).tag(5120)
                    }
                } footer: {
                    Text(L10n.t("Cache.AutoCleanHint"))
                        .font(.appFootnote)
                }

                Section(L10n.t("Cache.Categories")) {
                    ForEach(cache.categories) { category in
                        HStack(spacing: 12) {
                            Image(systemName: category.icon)
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                Text(String(format: L10n.t("AutoI.4171bb73a1"), String(describing: category.count)))
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
                        Label(L10n.t("Cache.ClearAll"), systemImage: "trash")
                    }
                    .disabled(cache.totalBytes == 0 || cache.isWorking)

                    Button {
                        ImageCache.clear()
                        cache.refresh()
                    } label: {
                        Label(L10n.t("Cache.ClearImages"), systemImage: "photo.on.rectangle")
                    }

                    Button(role: .destructive) {
                        ChatStore.shared.clearLoadedMessages()
                    } label: {
                        Label(L10n.t("Cache.ClearMessages"), systemImage: "bubble.left.and.bubble.right")
                    }
                } footer: {
                    Text(L10n.t("Cache.ClearMessagesHint"))
                        .font(.appFootnote)
                }
            }
            .navigationTitle(L10n.t("Cache.Title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .task { cache.refresh() }
            .overlay {
                if cache.isWorking {
                    ProgressView(L10n.t("Cache.Clearing"))
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .confirmationDialog(
                L10n.t("Cache.ClearCategory"),
                isPresented: Binding(
                    get: { pendingCategory != nil },
                    set: { if !$0 { pendingCategory = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let category = pendingCategory {
                    Button(String(format: L10n.t("Cache.ClearNamed"), category.title), role: .destructive) {
                        cache.clear(category)
                        pendingCategory = nil
                    }
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) { pendingCategory = nil }
            }
            .confirmationDialog(
                L10n.t("Cache.ClearAllConfirm"),
                isPresented: $showClearAll,
                titleVisibility: .visible
            ) {
                Button(L10n.t("Cache.ClearEverything"), role: .destructive) {
                    cache.clearAll()
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t("Cache.ClearAllHint"))
            }
        }
        .navigationViewStyle(.stack)
    }
}
