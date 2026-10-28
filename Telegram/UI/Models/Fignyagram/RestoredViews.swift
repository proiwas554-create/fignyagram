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
                    Toggle(L10n.t("Auto.1d2f7bc0f8"), isOn: $enabled)
                } footer: {
                    Text(L10n.t("Auto.5c33723f7e"))
                        .font(.appFootnote)
                }

                Section {
                    Toggle(L10n.t("Auto.5bdd925f3c"), isOn: $onlyPrivate)
                    Toggle(L10n.t("Auto.1275887465"), isOn: $onlyHumans)
                } footer: {
                    Text(L10n.t("Auto.6d52bc1eed"))
                        .font(.appFootnote)
                }
                .disabled(!enabled)

                Section {
                    NavigationLink {
                        NotificationScopeDetailView(title: NSLocalizedString("Generated.1a2aed5cd4eb", comment: ""), icon: "person", key: "Private")
                    } label: { Label(L10n.t("Auto.e1087ec78b"), systemImage: "person") }
                    NavigationLink {
                        NotificationScopeDetailView(title: NSLocalizedString("Generated.f530227e164d", comment: ""), icon: "person.2", key: "Groups")
                    } label: { Label(L10n.t("Auto.ebc417c95a"), systemImage: "person.2") }
                    NavigationLink {
                        NotificationScopeDetailView(title: NSLocalizedString("Generated.53b50dcd25e1", comment: ""), icon: "megaphone", key: "Channels")
                    } label: { Label(L10n.t("Auto.0c1119c13e"), systemImage: "megaphone") }
                } header: {
                    Text(L10n.t("Auto.f33dc46aa9"))
                } footer: {
                    Text(L10n.t("Auto.8e4ac9c845"))
                        .font(.appFootnote)
                }
                .disabled(!enabled)

                Section {
                    HStack {
                        Text(L10n.t("Auto.543ee0732d"))
                        Spacer()
                        Text(permissionText).foregroundColor(.secondary)
                    }
                    Button(L10n.t("Auto.63106994e4")) {
                        AppNotifications.shared.requestAuthorization()
                        refreshPermission()
                    }
                } footer: {
                    Text(L10n.t("Auto.8cfc442457"))
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
                Picker(L10n.t("Auto.00596788f6"), selection: $mute) {
                    Text(L10n.t("Auto.d3b9e44014")).tag(0)
                    Text(L10n.t("Auto.b56e1c416c")).tag(3600)
                    Text(L10n.t("Auto.1536267a9f")).tag(28800)
                    Text(L10n.t("Auto.cf9000d173")).tag(86400)
                    Text(L10n.t("Auto.b2eda19397")).tag(-1)
                }
                Toggle(L10n.t("Auto.2c476e3938"), isOn: $preview)
                Toggle(L10n.t("Auto.9329d824a2"), isOn: $sound)
            } footer: {
                Text(L10n.t("Auto.475d9aff6c"))
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
                            Text(L10n.t("Auto.a4578ef34d"))
                            Spacer()
                            Text("\(limits.maxMessagesPerChat)").monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                    Stepper(value: $limits.maxRenderedChats,
                            in: DisplayLimits.chatRange,
                            step: 10) {
                        HStack {
                            Text(L10n.t("Auto.b4dd5aed0c"))
                            Spacer()
                            Text("\(limits.maxRenderedChats)").monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text(L10n.t("Auto.f9e9f90115"))
                        .font(.appFootnote)
                }
            }
            .navigationTitle(L10n.t("Auto.73e8dc0ad7"))
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
