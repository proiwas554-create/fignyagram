import SwiftUI
import Translation

struct SettingsView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var privacy = PrivacyPreferences.shared
    @ObservedObject private var autoTranslation = AutoTranslationSettings.shared
    @State private var showTranslationSheet = false
    @State private var translationSample = "Hello, how are you?"
    @AppStorage("showMusicTab") private var showMusicTab = true
    @AppStorage("showNewsTab") private var showNewsTab = false
    @AppStorage("autoTextFileThreshold") private var autoTextFileThreshold = 0
    @ObservedObject private var globalSearch = GlobalSearchPreferences.shared
    @ObservedObject private var developer = DeveloperMode.shared
    @ObservedObject private var classicDesign = ClassicDesignMode.shared
    @ObservedObject private var translation = TranslationService.shared
    @AppStorage("notificationsDisabled") private var notificationsDisabled = false
    @AppStorage("showAdminAuthors") private var showAdminAuthors = true
    @AppStorage("disableAutoScroll") private var disableAutoScroll = false
    @AppStorage("anonymousForwarding") private var anonymousForwarding = true
    @AppStorage("hideSenderNames") private var hideSenderNames = false
    @AppStorage("recentContactsEnabled") private var recentContactsEnabled = true
    @Environment(\.dismiss) private var dismiss
    @State private var destination: SettingsDestination?
    @State private var showDeviceQR = false
    @State private var showDeviceResult = false
    @State private var deviceResultText = ""

    private enum SettingsDestination: String, Identifiable {
        case profile, cloudPassword, notifications, proxy, limits, optimization, downloads, cache, commands, scanner, developer, directStats, fonts, hardware, sessions
        var id: String { rawValue }
    }

    var body: some View {
        NavigationView {
            List {
                Section(L10n.t("Auto.547743e82f")) {
                    row(L10n.t("AutoT.ed903f8795"), icon: "network", value: .proxy)
                }

                Section {
                    Toggle(L10n.t("Auto.e64f567a69"), isOn: $recentContactsEnabled)
                    Button {
                        DeepLinkRouter.shared.pendingUsername = "fignyagram"
                        dismiss()
                    } label: {
                        HStack {
                            Label(L10n.t("Auto.6038f853ca"), systemImage: "megaphone")
                            Spacer()
                            Text("@fignyagram").foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Fignyagram")
                } footer: {
                    Text(L10n.t("Settings.RecentContactsHint"))
                        .font(.appFootnote)
                }

                Section {
                    Toggle(L10n.t("Auto.86f3cdd961"), isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "textSelectionEnabled") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "textSelectionEnabled") }
                    ))
                    row(L10n.t("AutoT.e479fdc532"), icon: "textformat", value: .fonts)
                } header: {
                    Text(L10n.t("Auto.065a4bdc2e"))
                } footer: {
                    Text(L10n.t("Auto.c34bbe2d43"))
                        .font(.appFootnote)
                }

                if ClassicDesignMode.isAvailable {
                    Section {
                        Toggle(L10n.t("Auto.efa0e8679f"), isOn: Binding(
                            get: { classicDesign.isEnabled },
                            set: { classicDesign.setEnabled($0) }
                        ))
                    } header: {
                        Text(L10n.t("Auto.065a4bdc2e"))
                    } footer: {
                        Text(L10n.t("Auto.14cc6719e6"))
                            .font(.appFootnote)
                    }
                }

                Section(L10n.t("Auto.a1ceab59e9")) {
                    row(L10n.t("AutoT.a46c372347"), icon: "person.crop.circle", value: .profile)
                    row(L10n.t("AutoT.067770493a"), icon: "laptopcomputer.and.iphone", value: .sessions)
                    row(L10n.t("AutoT.5a77c57a29"), icon: "lock.shield", value: .cloudPassword)
                    Button {
                        showDeviceQR = true
                    } label: {
                        Label(L10n.t("Auto.eb2d0f70a4"), systemImage: "qrcode.viewfinder")
                    }
                    Toggle(L10n.t("Common.Notifications"), isOn: Binding(
                        get: { !notificationsDisabled },
                        set: { enabled in
                            notificationsDisabled = !enabled
                            if !enabled {
                                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                            }
                        }
                    ))
                    row(L10n.t("AutoT.0fc9def45f"), icon: "bell.badge", value: .notifications)
                }

                Section {
                    row(L10n.t("AutoT.ce87c3f7c4"), icon: "wand.and.stars", value: .commands)
                } header: {
                    Text(L10n.t("Auto.b05019e764"))
                } footer: {
                    Text(L10n.t("Auto.1b29542fbe"))
                        .font(.appFootnote)
                }

                Section(L10n.t("Auto.5da932c117")) {
                    Button {
                        destination = .directStats
                    } label: {
                        Label(L10n.t("Auto.d4df6392c6"), systemImage: "person.2.wave.2")
                    }
                    Button {
                        destination = .scanner
                    } label: {
                        Label(L10n.t("Auto.32f7bac562"), systemImage: "qrcode.viewfinder")
                    }
                    if developer.isUnlocked {
                        Button {
                            destination = .developer
                        } label: {
                            Label(L10n.t("Auto.da0973949b"), systemImage: "hammer")
                        }
                    }
                }

                Section(L10n.t("Auto.d884c5b006")) {
                    row(L10n.t("AutoT.c2f7359a1b"), icon: "internaldrive", value: .downloads)
                    row(L10n.t("AutoT.dbc234480c"), icon: "externaldrive", value: .cache)
                    row(L10n.t("AutoT.7b900f6633"), icon: "slider.horizontal.3", value: .limits)
                    row(L10n.t("AutoT.c09fb8d62b"), icon: "bolt.batteryblock", value: .optimization)
                    row(L10n.t("Settings.Performance.Profile"), icon: "cpu", value: .hardware)
                }

                Section {
                    Toggle(L10n.t("Auto.eb1a7197f3"), isOn: $showAdminAuthors)
                    Toggle(L10n.t("Auto.85f8de3554"), isOn: $hideSenderNames)
                    Toggle(L10n.t("Auto.d75198a220"), isOn: $disableAutoScroll)
                    Toggle(L10n.t("Auto.4807ffc935"), isOn: $anonymousForwarding)
                    Toggle(L10n.t("Auto.7ff2d24fae"), isOn: $globalSearch.isEnabled)
                    Toggle(L10n.t("Auto.d936c359d6"), isOn: Binding(
                        get: { privacy.keepDeletedMessages },
                        set: { value in
                            privacy.keepDeletedMessages = value
                            if value {
                                ChatStore.shared.applyDeletedArchiveEverywhere()
                            } else {
                                ChatStore.shared.hideDeletedArchive()
                            }
                        }
                    ))
                    Toggle(L10n.t("Settings.BlockScreenshots"), isOn: Binding(
                        get: { privacy.blockScreenshots },
                        set: { privacy.blockScreenshots = $0 }
                    ))
                    Picker(L10n.t("Settings.SendTextAsFile"), selection: $autoTextFileThreshold) {
                        Text(L10n.t("Common.Never")).tag(0)
                        Text(L10n.string(NSLocalizedString("Generated.932a47f6d569", comment: ""), "2000 characters")).tag(2000)
                        Text(L10n.string(NSLocalizedString("Generated.e8c5c957c1ec", comment: ""), "4000 characters")).tag(4000)
                    }
                    NavigationLink(L10n.t("Settings.QuickReplies")) {
                        SnippetsSettingsView()
                    }
                    NavigationLink(L10n.t("Settings.ProfilesAndPin")) {
                        ProfilesSecurityView()
                    }
                    Button {
                        GuestMode.shared.enter()
                    } label: {
                        Label(L10n.t("Settings.EnterGuestMode"), systemImage: "theatermasks")
                    }
                    Toggle(L10n.t("Settings.MusicTab"), isOn: $showMusicTab)
                    Toggle(L10n.t("Settings.NewsTab"), isOn: $showNewsTab)
                    Picker(L10n.t("Translation.Mode"), selection: Binding(
                        get: { autoTranslation.mode },
                        set: { value in
                            autoTranslation.mode = value
                        }
                    )) {
                        ForEach(AutoTranslationSettings.Mode.allCases) { item in
                            Text(item.title)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .tag(item)
                        }
                    }
                    .disabled(!autoTranslation.isSupported)
                    Picker(L10n.t("Settings.TranslationLanguage"), selection: Binding(
                        get: { autoTranslation.targetLanguage },
                        set: { value in
                            autoTranslation.setTargetLanguage(value)
                            AutoTranslationManager.shared.requestLanguagePreparation()
                        }
                    )) {
                        ForEach(AutoTranslationSettings.supportedLanguages, id: \.code) { item in
                            Text(item.title).tag(item.code)
                        }
                    }
                    if autoTranslation.mode != .disabled {
                        Button {
                            AutoTranslationManager.shared.requestLanguagePreparation()
                            activateTranslationSheet()
                        } label: {
                            Label(L10n.t("Settings.ActivateTranslator"), systemImage: "arrow.down.circle")
                        }
                    }
                    Toggle(L10n.t("Settings.GhostMode"), isOn: Binding(
                        get: { TelegramClient.shared.isInvisible },
                        set: { value in
                            Task { try? await TelegramClient.shared.setInvisibleMode(value) }
                        }
                    ))
                    Toggle(L10n.t("Settings.GhostStories"), isOn: Binding(
                        get: { privacy.storyGhostMode },
                        set: { privacy.storyGhostMode = $0 }
                    ))
                    Toggle(L10n.t("Settings.IgnoreCopy"), isOn: Binding(
                        get: { privacy.ignoreCopyProtection },
                        set: { privacy.ignoreCopyProtection = $0 }
                    ))
                    Toggle(L10n.t("Auto.7964dec1cf"), isOn: Binding(
                        get: { AppLock.shared.isEnabled },
                        set: { value in
                            AppLock.shared.isEnabled = value
                            if value { AppLock.shared.lockIfNeeded() }
                        }
                    ))
                    Toggle(L10n.t("Auto.1177821baa"), isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "callViaApp") },
                        set: { UserDefaults.standard.set($0, forKey: "callViaApp") }
                    ))
                    .disabled(!VoIPBridge.engineAvailable())
                    if !VoIPBridge.engineAvailable() {
                        Text(L10n.t("Auto.3fcc4e1302"))
                            .font(.appFootnote)
                            .foregroundColor(.secondary)
                    }
                    Toggle(L10n.t("Auto.2792349a96"), isOn: Binding(
                        get: { client.isInvisible },
                        set: { value in
                            Task {
                                do { try await client.setInvisibleMode(value) }
                                catch { client.errorMessage = TelegramClient.describe(error) }
                            }
                        }
                    ))
                } header: {
                    Text(L10n.t("Auto.0899eda172"))
                } footer: {
                    Text(NSLocalizedString("Generated.7f0b0f9f7bac", comment: ""))
                        .font(.appFootnote)
                }

                Section {
                    Button(role: .destructive) {
                        client.logOut()
                        dismiss()
                    } label: {
                        Label(L10n.t("Auto.6d4183b79b"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .modifier(TranslationPresentationModifier(isPresented: $showTranslationSheet,
                                                  text: translationSample,
                                                  target: autoTranslation.targetLanguage))
        .navigationTitle(L10n.t("Common.Settings"))
        .onAppear { autoTranslation.reloadFromDefaults() }
            .modifier(GlassListModifier())
            .tint(.blue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .sheet(item: $destination) { item in
                switch item {
                case .profile: ProfileSettingsView()
                case .cloudPassword: CloudPasswordView()
                case .notifications: NotificationSettingsView()
                case .proxy: ProxySettingsView()
                case .limits: LimitsSettingsView()
                case .optimization: PerformanceSettingsView()
                case .downloads: DownloadedFilesView()
                case .cache: CacheSettingsView()
                case .commands: CommandPaletteView()
                case .scanner: UniversalScannerView()
                case .developer: DeveloperSettingsView()
                case .sessions: SessionsView()
                case .directStats: DirectMessageStatsView()
                case .fonts: FontSettingsView()
                case .hardware: HardwareSettingsView()
                }
            }
            .sheet(isPresented: $showDeviceQR) {
                QRCodeScannerSheet { code in
                    Task {
                        if await client.confirmOtherDeviceLogin(code) {
                            deviceResultText = NSLocalizedString("Generated.1c4673c8b852", comment: "")
                            showDeviceResult = true
                        }
                    }
                }
            }
            .alert(L10n.t("Common.Done"), isPresented: $showDeviceResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deviceResultText)
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Presents Apple's own translation sheet exactly once, from Settings.
    private func activateTranslationSheet() {
        translationSample = L10n.t("Settings.TranslationSample")
        showTranslationSheet = true
    }

    private func row(_ title: String, icon: String, value: SettingsDestination) -> some View {
        Button {
            destination = value
        } label: {
            Label(title, systemImage: icon)
        }
    }
}


/// Wraps `.translationPresentation` so the settings screen compiles on iOS 15
/// and shows Apple's download sheet only when the user asks for it.
private struct TranslationPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let text: String
    let target: String

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.translationPresentation(isPresented: $isPresented, text: text)
        } else {
            content
        }
    }
}
