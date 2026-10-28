import SwiftUI
import TDLibKit

struct DeveloperSettingsView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var performance = PerformanceMode.shared
    @ObservedObject private var developer = DeveloperMode.shared
    @ObservedObject private var monitor = PerformanceMonitor.shared
    @ObservedObject private var proxy = BuiltInProxyManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var verbosity: Double = 1
    @State private var showTerminal = false
    @State private var storageInfo: String?
    @State private var decodeConcurrency = 2
    @AppStorage("showFPS") private var showFPS = false
    @AppStorage("developerVerboseLogs") private var verboseLogs = false

    var body: some View {
        NavigationView {
            List {
                Section("Сборка") {
                    row("Версия", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    row("iOS", UIDevice.current.systemVersion)
                    row("TDLib API", "1.8.68")
                    row("Аккаунт", client.me.map { "\($0.id)" } ?? "—")
                }

                Section("Нагрузка приложения") {
                    row("Память", String(format: "%.1f МБ", monitor.memoryMB))
                    row("CPU", String(format: "%.1f%%", monitor.cpuPercent))
                    row("Потоки", "\(monitor.threadCount)")
                    row("Загружено сообщений", "\(monitor.loadedMessages)")
                    row("Загружено чатов", "\(monitor.loadedChats)")
                    row("Кэш", MessageFormatter.fileSize(monitor.cacheBytes))
                    Button("Обновить сейчас") { monitor.sample() }
                }

                Section {
                    Toggle("Показывать FPS", isOn: $showFPS)
                    Toggle("Подробные логи TDLib", isOn: $verboseLogs)
                        .onChange(of: verboseLogs) { enabled in
                            client.setLogVerbosity(enabled ? 3 : 1)
                        }
                    Button(L10n.t("Dev.SimulateMemory")) {
                        ImageCache.clear()
                        monitor.sample()
                    }
                    Button("Очистить кэш сообщений") {
                        ChatStore.shared.clearLoadedMessages()
                        monitor.sample()
                    }
                    Button(L10n.t("Dev.RestartProxy")) {
                        proxy.restart()
                    }
                    .disabled(!proxy.isEnabled)
                    Button(L10n.t("Dev.StorageStats")) {
                        Task {
                            storageInfo = await client.storageStatisticsSummary()
                        }
                    }
                    if let storageInfo {
                        Text(storageInfo).font(.appCaption).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Тесты")
                } footer: {
                    Text("Тестовые настройки не меняют данные аккаунта. FPS отображается поверх интерфейса после включения.")
                        .font(.appFootnote)
                }

                Section("Состояние") {
                    row("Чатов", "\(store.chats.count)")
                    row("Пользователей", "\(store.users.count)")
                    row("Кэш", MessageFormatter.fileSize(cache.totalBytes))
                    row("Оптимизация", performance.isEnabled ? performance.level.title : "выключена")
                    Button(L10n.t("Dev.RefreshStats")) { cache.refresh() }
                }

                Section {
                    Toggle("GPU-эффекты (Metal CoreImage)", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "gpuEffectsEnabled") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "gpuEffectsEnabled") }
                    ))
                    Toggle("Пакетная отрисовка (CATransaction)", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "renderBatchingEnabled") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "renderBatchingEnabled") }
                    ))
                    Stepper("Потоков декодирования: \(decodeConcurrency)", value: $decodeConcurrency, in: 1...4)
                        .onChange(of: decodeConcurrency) { value in
                            ImageCache.setDecodeConcurrency(value)
                        }
                    Button(L10n.t("Dev.LegacyProfile")) {
                        ImageCache.applyLegacyDeviceTuning()
                    }
                } header: {
                    Text("Графика и оптимизация")
                } footer: {
                    Text("Управление Metal/ProMotion, пакетной отрисовкой и числом потоков декодирования изображений.")
                        .font(.appFootnote)
                }

                Section(L10n.t("Dev.Console")) {
                    Button {
                        showTerminal = true
                    } label: {
                        Label("Командная строка / терминал", systemImage: "terminal")
                    }
                }

                Section("TDLib") {
                    Stepper("Log verbosity: \(Int(verbosity))", value: $verbosity, in: 0...5)
                    Button(L10n.t("Dev.ApplyLogLevel")) {
                        client.setLogVerbosity(Int(verbosity))
                    }
                }

                Section(L10n.t("Settings.Developer.Terminal")) {
                    NavigationLink(L10n.t("Settings.Automation.Macros")) {
                        MacroSettingsView()
                    }
                    Button("Очистить весь кэш", role: .destructive) {
                        cache.clearAll()
                    }
                    Button(L10n.t("Dev.Lock"), role: .destructive) {
                        developer.lock()
                        dismiss()
                    }
                }
            }
            .navigationTitle(L10n.t("Dev.Title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .task { cache.refresh() }
            .onAppear {
                monitor.start()
                decodeConcurrency = max(1, min(ProcessInfo.processInfo.activeProcessorCount / 2, 4))
            }
            .onDisappear { monitor.stop() }
            .sheet(isPresented: $showTerminal) {
                DeveloperTerminalView()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.footnote.monospacedDigit())
        }
    }
}
