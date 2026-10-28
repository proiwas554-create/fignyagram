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
                Section(L10n.t("Auto.0d7f2e6b48")) {
                    row(L10n.t("Dev.Version"), Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    row("iOS", UIDevice.current.systemVersion)
                    row("TDLib API", "1.8.68")
                    row(L10n.t("Dev.Account"), client.me.map { "\($0.id)" } ?? "—")
                }

                Section(L10n.t("Dev.AppLoad")) {
                    row("Память", String(format: "%.1f МБ", monitor.memoryMB))
                    row("CPU", String(format: "%.1f%%", monitor.cpuPercent))
                    row("Потоки", "\(monitor.threadCount)")
                    row(L10n.t("Dev.LoadedMessages"), "\(monitor.loadedMessages)")
                    row(L10n.t("Dev.LoadedChats"), "\(monitor.loadedChats)")
                    row(L10n.t("Dev.Cache"), MessageFormatter.fileSize(monitor.cacheBytes))
                    Button(L10n.t("Auto.efc373dea9")) { monitor.sample() }
                }

                Section {
                    Toggle(L10n.t("Auto.4cea4bc37d"), isOn: $showFPS)
                    Toggle(L10n.t("Auto.50770cdcde"), isOn: $verboseLogs)
                        .onChange(of: verboseLogs) { enabled in
                            client.setLogVerbosity(enabled ? 3 : 1)
                        }
                    Button(L10n.t("Dev.SimulateMemory")) {
                        ImageCache.clear()
                        monitor.sample()
                    }
                    Button(L10n.t("Auto.08126612ba")) {
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
                    Text(L10n.t("Auto.7f488607de"))
                } footer: {
                    Text(L10n.t("Auto.ae0df04654"))
                        .font(.appFootnote)
                }

                Section(L10n.t("Auto.23bdac65fb")) {
                    row("Чатов", "\(store.chats.count)")
                    row("Пользователей", "\(store.users.count)")
                    row(L10n.t("Dev.Cache"), MessageFormatter.fileSize(cache.totalBytes))
                    row("Оптимизация", performance.isEnabled ? performance.level.title : "выключена")
                    Button(L10n.t("Dev.RefreshStats")) { cache.refresh() }
                }

                Section {
                    Toggle(L10n.t("Auto.6e51b09768"), isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "gpuEffectsEnabled") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "gpuEffectsEnabled") }
                    ))
                    Toggle(L10n.t("Auto.5d46bb7fa7"), isOn: Binding(
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
                    Text(L10n.t("Dev.Graphics"))
                } footer: {
                    Text(L10n.t("Auto.d2cc8935b8"))
                        .font(.appFootnote)
                }

                Section(L10n.t("Dev.Console")) {
                    Button {
                        showTerminal = true
                    } label: {
                        Label(L10n.t("Auto.4169915af6"), systemImage: "terminal")
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
                    Button(L10n.t("Auto.610bc3b777"), role: .destructive) {
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
