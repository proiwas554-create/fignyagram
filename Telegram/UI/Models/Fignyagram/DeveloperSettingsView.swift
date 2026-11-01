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
                Section(L10n.header("Auto.0d7f2e6b48")) {
                    row(L10n.t("Dev.Version"), 
                        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    row("iOS", UIDevice.current.systemVersion)
                    row("TDLib API", "1.8.69")
                }
            }
            .navigationTitle("Меню разработчика")
            .toolbar {
                Button("Закрыть") { dismiss() }
            }
        }
    }
    
    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}
