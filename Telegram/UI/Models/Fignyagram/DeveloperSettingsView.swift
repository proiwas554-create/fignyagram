import SwiftUI
import TDLibKit

/// Developer hub: rendering switches, TDLib console, live load metrics and
/// destructive maintenance actions. Kept behind `DeveloperMode` so it never
/// shows up for regular users.
struct DeveloperSettingsView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var performance = PerformanceMode.shared
    @ObservedObject private var developer = DeveloperMode.shared
    @ObservedObject private var monitor = DeveloperMonitor.shared
    @ObservedObject private var proxy = BuiltInProxyManager.shared

    @Environment(\.dismiss) private var dismiss

    @State private var verbosity = 1
    @State private var showStorageStats = false
    @State private var storageStats = ""

    @State private var lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    @AppStorage(DuoSimulationKeys.active) private var duoSimulationActive = false
    @AppStorage(DuoSimulationKeys.orientation) private var duoOrientation = DuoSimulationOrientation.portrait.rawValue
    @AppStorage(DuoSimulationKeys.foldWidth) private var duoFoldWidth = 10.0

    var body: some View {
        NavigationView {
            List {
                duoSimulatorSection
                graphicsSection
                consoleSection
                tdlibSection
                terminalSection
                deviceSection
                buildSection
                loadSection
                testsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Меню разработчика")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .onAppear {
                lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                monitor.start()
                cache.refresh()
            }
            .onDisappear {
                monitor.stop()
            }
            .alert("Статистика хранилища", isPresented: $showStorageStats) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(storageStats)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Симулятор iPhone Duo

    private var duoSimulatorSection: some View {
        Section {
            Toggle("Режим симуляции Duo", isOn: $duoSimulationActive)

            Picker("Ориентация симуляции", selection: $duoOrientation) {
                ForEach(DuoSimulationOrientation.allCases) { orientation in
                    Text(orientation.title).tag(orientation.rawValue)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Ширина линии сгиба")
                    Spacer()
                    Text("\(Int(duoFoldWidth)) пкс")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $duoFoldWidth, in: 10...100, step: 5)
            }
            .opacity(duoSimulationActive ? 1 : 0.45)
            .disabled(!duoSimulationActive)
        } header: {
            Text("СИМУЛЯТОР IPHONE DUO (ТЕСТ ИНТЕРФЕЙСА)")
        } footer: {
            Text("Вертикальная ориентация сворачивает оболочку в компактный TabView, горизонтальная разворачивает три панели. Работает и на реальном iPhone.")
                .font(.appFootnote)
        }
    }

    // MARK: - Графика и оптимизация

    private var graphicsSection: some View {
        Section {
            Toggle("GPU-эффекты (Metal CoreImage)", isOn: boolBinding(\.useMetalCoreImage))
            Toggle("Пакетная отрисовка (CATransaction)", isOn: boolBinding(\.enableBatchRendering))
            Stepper(value: intBinding(\.decodeConcurrency), in: 1...8) {
                HStack {
                    Text("Потоков декодирования")
                    Spacer()
                    Text("\(performance.decodeConcurrency)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            Button("Применить облегчённый профиль") {
                performance.applyLightProfile()
            }
        } header: {
            Text("ГРАФИКА И ОПТИМИЗАЦИЯ")
        }
    }

    // MARK: - Консоль

    private var consoleSection: some View {
        Section {
            NavigationLink {
                DeveloperTerminalView()
            } label: {
                Label("Командная строка / терминал", systemImage: "terminal")
            }
        } header: {
            Text("КОНСОЛЬ")
        }
    }

    // MARK: - TDLib

    private var tdlibSection: some View {
        Section {
            Stepper(value: $verbosity, in: 0...5) {
                HStack {
                    Text("Log verbosity")
                    Spacer()
                    Text("\(verbosity)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            Button("Применить уровень логов") {
                client.setLogWithVerbosityLevel(verbosity)
            }
        } header: {
            Text("TDLIB")
        }
    }

    // MARK: - Терминал разработчика

    private var terminalSection: some View {
        Section {
            NavigationLink {
                DeveloperAutomationView()
            } label: {
                Label("Автоматизация (макросы)", systemImage: "wand.and.stars")
            }

            Button(role: .destructive) {
                cache.clearAll()
            } label: {
                Text("Очистить весь кэш")
            }

            Button(role: .destructive) {
                developer.lock()
                dismiss()
            } label: {
                Text("Заблокировать режим разработчика")
            }
        } header: {
            Text("ТЕРМИНАЛ РАЗРАБОТЧИКА")
        }
    }

    // MARK: - Устройство

    private var deviceSection: some View {
        Section {
            HStack {
                Text("Модель")
                Spacer()
                #if targetEnvironment(macCatalyst)
                Text("MacBook (Catalyst Architecture)")
                    .foregroundColor(.secondary)
                #else
                Text(UIDevice.current.model)
                    .foregroundColor(.secondary)
                #endif
            }

            row("Класс", monitor.deviceClass)
            row("Частота экрана", "\(monitor.maxRefreshRate) Гц", mono: true)
            row("Режим энергосбережения", lowPowerModeEnabled ? "Включён" : "Выключен")

            if lowPowerModeEnabled {
                Text("Частота заблокирована операционной системой на 60 Гц, так как включен режим энергосбережения macOS.")
                    .font(.appFootnote)
                    .foregroundColor(.orange)
            }
        } header: {
            Text("УСТРОЙСТВО")
        }
    }

    // MARK: - Сборка

    private var buildSection: some View {
        Section {
            row("Версия", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            row("iOS", UIDevice.current.systemVersion)
            row("TDLib API", "1.8.69")
            row("Аккаунт", accountTitle)
        } header: {
            Text("СБОРКА")
        }
    }

    // MARK: - Нагрузка приложения

    private var loadSection: some View {
        Section {
            row("Память", String(format: "%.1f МБ", monitor.memoryMB), mono: true)
            row("CPU", String(format: "%.1f %%", monitor.cpuPercent), mono: true)
            row("Потоков", "\(monitor.threadCount)", mono: true)
            row("Загружено сообщений", "\(loadedMessages)", mono: true)
            row("Загружено чатов", "\(store.chats.count)", mono: true)

            Button("Обновить сейчас") {
                monitor.refreshNow()
                cache.refresh()
            }
        } header: {
            Text("НАГРУЗКА ПРИЛОЖЕНИЯ")
        }
    }

    // MARK: - Тесты

    private var testsSection: some View {
        Section {
            Toggle("Показывать FPS", isOn: boolBinding(\.showFPS))
            Toggle("Подробные логи TDLib", isOn: boolBinding(\.developerVerboseLogs))

            Button("Симулировать нехватку памяти") {
                URLCache.shared.removeAllCachedResponses()
            }
            Button("Очистить кэш сообщений") {
                store.clearLoadedMessages()
            }
            Button("Перезапустить прокси") {
                proxy.restart()
            }
            Button("Статистика хранилища") {
                storageStats = storageSummary()
                showStorageStats = true
            }
        } header: {
            Text("ТЕСТЫ")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .modifier(MonoDigits(enabled: mono))
                .multilineTextAlignment(.trailing)
        }
    }

    private var loadedMessages: Int {
        store.messages.values.reduce(0) { $0 + $1.count }
    }

    private var accountTitle: String {
        guard let me = client.me else { return "—" }
        let name = [me.firstName, me.lastName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !name.isEmpty { return name }
        if let username = me.usernames?.activeUsernames.first, !username.isEmpty {
            return "@\(username)"
        }
        return "—"
    }

    private func storageSummary() -> String {
        guard !cache.categories.isEmpty else {
            return "Кэш пуст"
        }
        let total = ByteCountFormatter.string(fromByteCount: cache.totalBytes, countStyle: .file)
        let lines = cache.categories.map { category in
            let size = ByteCountFormatter.string(fromByteCount: category.bytes, countStyle: .file)
            return "\(category.title): \(size) (\(category.count))"
        }
        return (["Всего: \(total)"] + lines).joined(separator: "\n")
    }

    private func boolBinding(_ keyPath: ReferenceWritableKeyPath<PerformanceMode, Bool>) -> Binding<Bool> {
        Binding(
            get: { performance[keyPath: keyPath] },
            set: { performance[keyPath: keyPath] = $0 }
        )
    }

    private func intBinding(_ keyPath: ReferenceWritableKeyPath<PerformanceMode, Int>) -> Binding<Int> {
        Binding(
            get: { performance[keyPath: keyPath] },
            set: { performance[keyPath: keyPath] = $0 }
        )
    }
}

/// Placeholder for the macro automation screen: the hub must never crash while
/// the real editor is still being built.
struct DeveloperAutomationView: View {
    var body: some View {
        List {
            Section {
                Text("Редактор макросов появится в следующем обновлении.")
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Автоматизация (макросы)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MonoDigits: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.monospacedDigit()
        } else {
            content
        }
    }
}
