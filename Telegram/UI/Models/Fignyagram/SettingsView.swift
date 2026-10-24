import SwiftUI

struct SettingsView: View {
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var privacy = PrivacyPreferences.shared
    @ObservedObject private var globalSearch = GlobalSearchPreferences.shared
    @ObservedObject private var developer = DeveloperMode.shared
    @ObservedObject private var classicDesign = ClassicDesignMode.shared
    @ObservedObject private var translation = TranslationService.shared
    @AppStorage("notificationsDisabled") private var notificationsDisabled = false
    @AppStorage("showAdminAuthors") private var showAdminAuthors = true
    @AppStorage("disableAutoScroll") private var disableAutoScroll = false
    @AppStorage("anonymousForwarding") private var anonymousForwarding = true
    @AppStorage("hideSenderNames") private var hideSenderNames = false
    @Environment(\.dismiss) private var dismiss
    @State private var destination: SettingsDestination?
    @State private var showDeviceQR = false
    @State private var showDeviceResult = false
    @State private var deviceResultText = ""

    private enum SettingsDestination: String, Identifiable {
        case profile, cloudPassword, notifications, proxy, limits, optimization, downloads, cache, commands, scanner, developer, directStats, fonts, hardware
        var id: String { rawValue }
    }

    var body: some View {
        NavigationView {
            List {
                Section("Сеть") {
                    row("Прокси", icon: "network", value: .proxy)
                }

                Section {
                    Toggle("Выделение текста в сообщениях", isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "textSelectionEnabled") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "textSelectionEnabled") }
                    ))
                    Toggle("Переводить интерфейс на английский", isOn: Binding(
                        get: { translation.isEnabled },
                        set: { value in
                            UserDefaults.standard.set(true, forKey: "translationUserOverride")
                            translation.isEnabled = value
                        }
                    ))
                    Toggle("Переводить сообщения", isOn: Binding(
                        get: { translation.autoTranslateMessages },
                        set: { value in
                            UserDefaults.standard.set(true, forKey: "translationUserOverride")
                            translation.autoTranslateMessages = value
                        }
                    ))
                    row("Шрифт", icon: "textformat", value: .fonts)
                } header: {
                    Text("Оформление")
                } footer: {
                    Text("Перевод интерфейса выполняется локальными строками приложения. Перевод сообщений использует онлайн-сервис MyMemory и требует интернет.")
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
                    Toggle("Показывать удалённые сообщения", isOn: $privacy.keepDeletedMessages)
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
