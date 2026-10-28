import SwiftUI

struct SettingsView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var privacy = PrivacyPreferences.shared
    @ObservedObject private var autoTranslation = AutoTranslationSettings.shared
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
                Section("Сеть") {
                    row("Прокси", icon: "network", value: .proxy)
                }

                Section {
                    Toggle("Показывать недавние контакты", isOn: $recentContactsEnabled)
                    Button {
                        DeepLinkRouter.shared.pendingUsername = "fignyagram"
                        dismiss()
                    } label: {
                        HStack {
                            Label("Официальный канал", systemImage: "megaphone")
                            Spacer()
                            Text("@fignyagram").foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Fignyagram")
                } footer: {
                    Text("Недавние контакты показываются в истории поиска (\(Image(systemName: "clock.arrow.circlepath")) в списке чатов).")
                        .font(.appFootnote)
                }

                Section {
                    Toggle("Выделение текста в сообщениях", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "textSelectionEnabled") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "textSelectionEnabled") }
                    ))
                    row("Шрифт", icon: "textformat", value: .fonts)
                } header: {
                    Text("Оформление")
                } footer: {
                    Text("Интерфейс переводится системной локализацией iOS. Сообщения переводятся на устройстве через Apple Translation — без интернета и без сторонних сервисов.")
                        .font(.appFootnote)
                }

                if ClassicDesignMode.isAvailable {
                    Section {
                        Toggle("Классический дизайн iOS 18", isOn: Binding(
                            get: { classicDesign.isEnabled },
                            set: { classicDesign.setEnabled($0) }
                        ))
                    } header: {
                        Text("Оформление")
                    } footer: {
                        Text("Пересоздаёт плоские панели и фон в стиле iOS 18 на уровне приложения. Системные элементы iOS 26, которыми управляет Apple, могут выглядеть иначе.")
                            .font(.appFootnote)
                    }
                }

                Section("Аккаунт") {
                    row("Профиль", icon: "person.crop.circle", value: .profile)
                    row("Устройства и сессии", icon: "laptopcomputer.and.iphone", value: .sessions)
                    row("Облачный пароль", icon: "lock.shield", value: .cloudPassword)
                    Button {
                        showDeviceQR = true
                    } label: {
                        Label("Подключить устройство по QR", systemImage: "qrcode.viewfinder")
                    }
                    Toggle("Уведомления", isOn: Binding(
                        get: { !notificationsDisabled },
                        set: { enabled in
                            notificationsDisabled = !enabled
                            if !enabled {
                                UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                            }
                        }
                    ))
                    row("Настройки уведомлений", icon: "bell.badge", value: .notifications)
                }

                Section {
                    row("Команды", icon: "wand.and.stars", value: .commands)
                } header: {
                    Text("Быстрые действия")
                } footer: {
                    Text("Введите команду текстом — приложение выполнит её внутри себя.")
                        .font(.appFootnote)
                }

                Section("Инструменты") {
                    Button {
                        destination = .directStats
                    } label: {
                        Label("Статистика личных сообщений", systemImage: "person.2.wave.2")
                    }
                    Button {
                        destination = .scanner
                    } label: {
                        Label("Сканер QR-кодов", systemImage: "qrcode.viewfinder")
                    }
                    if developer.isUnlocked {
                        Button {
                            destination = .developer
                        } label: {
                            Label("Для разработчиков", systemImage: "hammer")
                        }
                    }
                }

                Section("Данные и память") {
                    row("Скачанные файлы", icon: "internaldrive", value: .downloads)
                    row("Память и кэш", icon: "externaldrive", value: .cache)
                    row("Ограничения отображения", icon: "slider.horizontal.3", value: .limits)
                    row("Оптимизация", icon: "bolt.batteryblock", value: .optimization)
                    row("Производительность и нагрев", icon: "cpu", value: .hardware)
                }

                Section {
                    Toggle("Подписывать авторов в каналах", isOn: $showAdminAuthors)
                    Toggle("Скрывать имена отправителей", isOn: $hideSenderNames)
                    Toggle("Отключить автоматическую прокрутку", isOn: $disableAutoScroll)
                    Toggle("Пересылать без автора", isOn: $anonymousForwarding)
                    Toggle("Глобальный поиск", isOn: $globalSearch.isEnabled)
                    Toggle("Показывать удалённые сообщения", isOn: Binding(
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
                    Toggle(NSLocalizedString("Settings.BlockShots", comment: ""), isOn: Binding(
                        get: { privacy.blockScreenshots },
                        set: { privacy.blockScreenshots = $0 }
                    ))
                    Picker(NSLocalizedString("Settings.AutoFile", comment: ""), selection: $autoTextFileThreshold) {
                        Text(NSLocalizedString("Common.Never", comment: "")).tag(0)
                        Text(L10n.string("2000 символов", "2000 characters")).tag(2000)
                        Text(L10n.string("4000 символов", "4000 characters")).tag(4000)
                    }
                    NavigationLink(NSLocalizedString("Settings.QuickReplies", comment: "")) {
                        SnippetsSettingsView()
                    }
                    NavigationLink(NSLocalizedString("Settings.Profiles", comment: "")) {
                        ProfilesSecurityView()
                    }
                    Button {
                        GuestMode.shared.enter()
                    } label: {
                        Label(NSLocalizedString("Settings.GuestMode", comment: ""), systemImage: "theatermasks")
                    }
                    Toggle(NSLocalizedString("Settings.Tabs.Music", comment: ""), isOn: $showMusicTab)
                    Toggle(NSLocalizedString("Settings.Tabs.News", comment: ""), isOn: $showNewsTab)
                    Toggle(NSLocalizedString("Settings.Translate.Title", comment: ""), isOn: Binding(
                        get: { autoTranslation.isEnabled },
                        set: { value in
                            autoTranslation.isEnabled = value && autoTranslation.isSupported
                        }
                    ))
                    .disabled(!autoTranslation.isSupported)
                    Picker(NSLocalizedString("Settings.Translate.Language", comment: ""), selection: Binding(
                        get: { autoTranslation.targetLanguage },
                        set: { autoTranslation.targetLanguage = $0 }
                    )) {
                        ForEach(AutoTranslationSettings.supportedLanguages, id: \.code) { item in
                            Text(item.title).tag(item.code)
                        }
                    }
                    Toggle(NSLocalizedString("Settings.GhostStories", comment: ""), isOn: Binding(
                        get: { privacy.storyGhostMode },
                        set: { privacy.storyGhostMode = $0 }
                    ))
                    Toggle(NSLocalizedString("Settings.IgnoreCopy", comment: ""), isOn: Binding(
                        get: { privacy.ignoreCopyProtection },
                        set: { privacy.ignoreCopyProtection = $0 }
                    ))
                    Toggle("Блокировка Face ID / Touch ID", isOn: Binding(
                        get: { AppLock.shared.isEnabled },
                        set: { value in
                            AppLock.shared.isEnabled = value
                            if value { AppLock.shared.lockIfNeeded() }
                        }
                    ))
                    Toggle("Звонки через приложение", isOn: Binding(
                        get: { UserDefaults.standard.bool(forKey: "callViaApp") },
                        set: { UserDefaults.standard.set($0, forKey: "callViaApp") }
                    ))
                    .disabled(!VoIPBridge.engineAvailable())
                    if !VoIPBridge.engineAvailable() {
                        Text("Встроенный VoIP-движок отключён: аудиозвонки идут через системную звонилку, видеозвонки недоступны. Для включения нужен готовый TelegramVoIP.framework.")
                            .font(.appFootnote)
                            .foregroundColor(.secondary)
                    }
                    Toggle("Режим невидимки", isOn: Binding(
                        get: { client.isInvisible },
                        set: { value in
                            Task {
                                do { try await client.setInvisibleMode(value) }
                                catch { client.errorMessage = TelegramClient.describe(error) }
                            }
                        }
                    ))
                } header: {
                    Text("Приватность")
                } footer: {
                    Text("Глобальный поиск ищет также сообщения и музыку. При выключении остаются поиск по чатам, каналам и контактам.\n\nСообщения, удалённые другими пользователями, останутся в локальном кэше этого устройства. Это работает только для уже загруженных сообщений. Всё на вашей совести.")
                        .font(.appFootnote)
                }

                Section {
                    Button(role: .destructive) {
                        client.logOut()
                        dismiss()
                    } label: {
                        Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Настройки")
            .modifier(GlassListModifier())
            .tint(.blue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
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
                            deviceResultText = "Устройство вошло в текущий аккаунт."
                            showDeviceResult = true
                        }
                    }
                }
            }
            .alert("Готово", isPresented: $showDeviceResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deviceResultText)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ title: LocalizedStringKey, icon: String, value: SettingsDestination) -> some View {
        Button {
            destination = value
        } label: {
            Label(title, systemImage: icon)
        }
    }
}
