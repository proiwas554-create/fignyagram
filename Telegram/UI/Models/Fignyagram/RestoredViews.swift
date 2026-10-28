import SwiftUI
import Combine
import TDLibKit
import UserNotifications

/// Mute durations for chat notification settings.
enum MuteOption: Int, CaseIterable, Identifiable {
    case hour1 = 3600
    case hours8 = 28800
    case day1 = 86400
    case forever = -1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .hour1: return "1 час"
        case .hours8: return "8 часов"
        case .day1: return "1 день"
        case .forever: return "Навсегда"
        }
    }
}

/// Notification settings matching the original two-level layout.
struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notificationsEnabled") private var enabled = true
    @AppStorage("notificationsOnlyPrivate") private var onlyPrivate = false
    @AppStorage("notificationsOnlyFromHumans") private var onlyHumans = false
    @State private var permissionText = "…"

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Уведомления включены", isOn: $enabled)
                } footer: {
                    Text("Полностью отключает все локальные уведомления, включая личные сообщения и группы.")
                        .font(.appFootnote)
                }

                Section {
                    Toggle("Только личные сообщения", isOn: $onlyPrivate)
                    Toggle("Только от людей", isOn: $onlyHumans)
                } footer: {
                    Text("Первый переключатель отключает уведомления из групп и каналов. Второй скрывает уведомления от ботов — сообщения обычных людей продолжат приходить по настройкам ниже.")
                        .font(.appFootnote)
                }
                .disabled(!enabled)

                Section {
                    NavigationLink {
                        NotificationScopeDetailView(title: "Личные чаты", icon: "person", key: "Private")
                    } label: { Label("Личные чаты", systemImage: "person") }
                    NavigationLink {
                        NotificationScopeDetailView(title: "Группы", icon: "person.2", key: "Groups")
                    } label: { Label("Группы", systemImage: "person.2") }
                    NavigationLink {
                        NotificationScopeDetailView(title: "Каналы", icon: "megaphone", key: "Channels")
                    } label: { Label("Каналы", systemImage: "megaphone") }
                } header: {
                    Text("Источники уведомлений")
                } footer: {
                    Text("Отдельные чаты и каналы можно замьютить колокольчиком в верхней панели чата.")
                        .font(.appFootnote)
                }
                .disabled(!enabled)

                Section {
                    HStack {
                        Text("Разрешение iOS")
                        Spacer()
                        Text(permissionText).foregroundColor(.secondary)
                    }
                    Button("Запросить разрешение") {
                        AppNotifications.shared.requestAuthorization()
                        refreshPermission()
                    }
                } footer: {
                    Text("Локальные уведомления работают, пока приложение запущено или ещё не выгружено из памяти.")
                        .font(.appFootnote)
                }
            }
            .navigationTitle(L10n.t("Common.Notifications"))
            .modifier(GlassListModifier())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .onAppear { refreshPermission() }
        }
        .navigationViewStyle(.stack)
    }

    private func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "Разрешены"
            case .denied: text = "Запрещены"
            case .notDetermined: text = "Не запрошены"
            @unknown default: text = "—"
            }
            DispatchQueue.main.async { permissionText = text }
        }
    }
}

struct NotificationScopeDetailView: View {
    let title: String
    let icon: String
    let key: String

    @AppStorage private var enabled: Bool
    @AppStorage private var mute: Int
    @AppStorage private var preview: Bool
    @AppStorage private var sound: Bool

    init(title: String, icon: String, key: String) {
        self.title = title
        self.icon = icon
        self.key = key
        _enabled = AppStorage(wrappedValue: true, "notify\(key)Enabled")
        _mute = AppStorage(wrappedValue: 0, "notify\(key)Mute")
        _preview = AppStorage(wrappedValue: true, "notify\(key)Preview")
        _sound = AppStorage(wrappedValue: true, "notify\(key)Sound")
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("Common.Notifications"), isOn: $enabled)
                Picker("Не беспокоить", selection: $mute) {
                    Text("По умолчанию").tag(0)
                    Text("1 час").tag(3600)
                    Text("8 часов").tag(28800)
                    Text("1 день").tag(86400)
                    Text("Навсегда").tag(-1)
                }
                Toggle("Текст сообщения", isOn: $preview)
                Toggle("Звук", isOn: $sound)
            } footer: {
                Text("Эти настройки применяются ко всем чатам этого типа, если у чата нет индивидуальных настроек.")
                    .font(.appFootnote)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!enabled)
    }
}

/// Rendering limits (restored screen).
struct LimitsSettingsView: View {
    @ObservedObject private var limits = DisplayLimits.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Stepper(value: $limits.maxMessagesPerChat,
                            in: DisplayLimits.messageRange,
                            step: 20) {
                        HStack {
                            Text("Сообщений в чате")
                            Spacer()
                            Text("\(limits.maxMessagesPerChat)").monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                    Stepper(value: $limits.maxRenderedChats,
                            in: DisplayLimits.chatRange,
                            step: 10) {
                        HStack {
                            Text("Чатов в списке")
                            Spacer()
                            Text("\(limits.maxRenderedChats)").monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("Ограничения влияют только на объём одновременно отображаемых данных и не удаляют историю.")
                        .font(.appFootnote)
                }
            }
            .navigationTitle("Лимиты отображения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

extension ChatNotificationSettings {
    func replacing(
        muteFor: Int? = nil,
        useDefaultMuteFor: Bool? = nil,
        soundId: TdInt64? = nil,
        useDefaultSound: Bool? = nil,
        showPreview: Bool? = nil,
        useDefaultShowPreview: Bool? = nil,
        disableMentionNotifications: Bool? = nil,
        useDefaultDisableMentionNotifications: Bool? = nil,
        useDefaultDisablePinnedMessageNotifications: Bool? = nil
    ) -> ChatNotificationSettings {
        ChatNotificationSettings(
            disableMentionNotifications: disableMentionNotifications ?? self.disableMentionNotifications,
            disablePinnedMessageNotifications: disablePinnedMessageNotifications,
            muteFor: muteFor ?? self.muteFor,
            muteStories: muteStories,
            showPreview: showPreview ?? self.showPreview,
            showStoryPoster: showStoryPoster,
            soundId: soundId ?? self.soundId,
            storySoundId: storySoundId,
            useDefaultDisableMentionNotifications: useDefaultDisableMentionNotifications ?? self.useDefaultDisableMentionNotifications,
            useDefaultDisablePinnedMessageNotifications: useDefaultDisablePinnedMessageNotifications ?? self.useDefaultDisablePinnedMessageNotifications,
            useDefaultMuteFor: useDefaultMuteFor ?? self.useDefaultMuteFor,
            useDefaultMuteStories: useDefaultMuteStories,
            useDefaultShowPreview: useDefaultShowPreview ?? self.useDefaultShowPreview,
            useDefaultShowStoryPoster: useDefaultShowStoryPoster,
            useDefaultSound: useDefaultSound ?? self.useDefaultSound,
            useDefaultStorySound: useDefaultStorySound
        )
    }

    func resettingToDefaults() -> ChatNotificationSettings {
        replacing(
            useDefaultMuteFor: true,
            useDefaultSound: true,
            useDefaultShowPreview: true,
            useDefaultDisableMentionNotifications: true,
            useDefaultDisablePinnedMessageNotifications: true
        )
    }
}
