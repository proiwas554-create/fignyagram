import Foundation
import UIKit
import Combine
import UserNotifications
import TDLibKit

/// Local notifications for builds distributed without an APNs backend.
///
/// A sideloaded IPA has no push server, so remote notifications are impossible.
/// These notifications are created from live TDLib updates and are delivered while
/// the app is running: in the foreground or during the short time iOS keeps the
/// process alive after it goes to the background. Notification settings (scope,
/// per-chat mute/sound/preview) are respected.
@MainActor
final class AppNotifications: NSObject, ObservableObject {
    static let shared = AppNotifications()

    /// Chat id from a tapped notification; the chat list picks it up and opens the chat.
    @Published var pendingChatId: Int64?

    private let center = UNUserNotificationCenter.current()
    private var scopeSettings: [NotificationSettingsScope: ScopeNotificationSettings] = [:]
    private var didRequestAuthorization = false
    private var lastSettingsRefresh = Date.distantPast

    private override init() {
        super.init()
    }

    /// Must be called before the app finishes launching so taps are delivered.
    func activate() {
        center.delegate = self
    }

    func requestAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    /// Refreshes the cached per-category settings used to decide whether to notify.
    /// Throttled because TDLib requests are not free.
    func refreshSettings(force: Bool = false) async {
        guard TelegramClient.shared.isAuthorized else { return }
        guard force || Date().timeIntervalSince(lastSettingsRefresh) > 300 else { return }
        lastSettingsRefresh = Date()
        let scopes: [NotificationSettingsScope] = [
            .notificationSettingsScopePrivateChats,
            .notificationSettingsScopeGroupChats,
            .notificationSettingsScopeChannelChats
        ]
        for scope in scopes {
            if let settings = try? await TelegramClient.shared.notificationSettings(scope: scope) {
                scopeSettings[scope] = settings
            }
        }
    }

    func update(scope: NotificationSettingsScope, settings: ScopeNotificationSettings) {
        scopeSettings[scope] = settings
    }

    /// Called for every incoming message; decides whether to show a local notification.
    func notify(about message: TDLibKit.Message, isChatOpen: Bool) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "notificationsDisabled") { return }
        if defaults.object(forKey: "notificationsEnabled") as? Bool == false { return }
        guard !message.isOutgoing else { return }
        guard let chat = ChatStore.shared.chats[message.chatId] else { return }
        // Never notify for Saved Messages or for messages sent by the current user.
        if let selfId = TelegramClient.shared.me?.id {
            if chat.privateUserId == selfId { return }
            if case .messageSenderUser(let sender) = message.senderId, sender.userId == selfId {
                return
            }
        }
        guard !ChatStore.shared.isSenderBlocked(message.senderId) else { return }
        // Optional privacy mode: private chats only, no groups/channels.
        if UserDefaults.standard.bool(forKey: "notificationsOnlyPrivate"),
           chat.privateUserId == nil {
            return
        }
        // Per-chat-type switches (Settings → Notifications).
        if chat.isChannel, defaults.object(forKey: "notifyChannels") as? Bool == false { return }
        if chat.isGroup, defaults.object(forKey: "notifyGroups") as? Bool == false { return }
        if chat.privateUserId != nil, defaults.object(forKey: "notifyPrivateChats") as? Bool == false { return }
        // Optional: never notify about messages sent by bots.
        if UserDefaults.standard.bool(forKey: "notificationsOnlyFromHumans"),
           case .messageSenderUser(let sender) = message.senderId,
           let userType = ChatStore.shared.users[sender.userId]?.type,
           case .userTypeBot = userType {
            return
        }
        // Don't cover the conversation the user is actively reading.
        if isChatOpen && UIApplication.shared.applicationState == .active { return }

        guard MessageFormatter.serviceText(message.content) == nil else { return }

        var settings = effectiveSettings(for: chat)
        let scopeKey = chat.isChannel ? "Channels" : (chat.isGroup ? "Groups" : "Private")
        if defaults.object(forKey: "notify\(scopeKey)Enabled") as? Bool == false { return }
        if let mute = defaults.object(forKey: "notify\(scopeKey)Mute") as? Int, mute != 0 {
            settings = EffectiveSettings(
                muteFor: mute,
                sound: settings.sound,
                showPreview: settings.showPreview
            )
        }
        if defaults.object(forKey: "notify\(scopeKey)Preview") as? Bool == false {
            settings = EffectiveSettings(muteFor: settings.muteFor, sound: settings.sound, showPreview: false)
        }
        if defaults.object(forKey: "notify\(scopeKey)Sound") as? Bool == false {
            settings = EffectiveSettings(muteFor: settings.muteFor, sound: false, showPreview: settings.showPreview)
        }
        guard settings.muteFor == 0 else { return }

        let preview = MessageFormatter.preview(message.content)
        guard !preview.isEmpty else { return }

        let content = UNMutableNotificationContent()
        let sender = ChatStore.shared.senderName(message.senderId)
        let displayChatTitle = LocalAliases.shared.chatAlias(chat.id) ?? chat.title
        if chat.isGroup || chat.isChannel {
            content.title = displayChatTitle
            if sender != displayChatTitle, !sender.isEmpty {
                content.subtitle = sender
            }
        } else {
            content.title = sender.isEmpty ? displayChatTitle : sender
        }
        let previewGlobal = defaults.object(forKey: "notificationPreview") as? Bool ?? true
        let soundGlobal = defaults.object(forKey: "notificationSound") as? Bool ?? true
        content.body = (settings.showPreview && previewGlobal) ? preview : NSLocalizedString("Generated.29edddcb8972", comment: "")
        content.sound = (settings.sound && soundGlobal) ? .default : nil
        content.threadIdentifier = "chat-\(chat.id)"
        content.userInfo = ["chatId": chat.id]

        // One replaceable notification per chat instead of one per message:
        // keeps the notification center bounded during long sessions.
        let request = UNNotificationRequest(
            identifier: "chat-\(chat.id)",
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    /// Removes a chat's pending/delivered notifications when it is opened.
    func clearNotifications(chatId: Int64) {
        let identifier = "chat-\(chatId)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func effectiveSettings(for chat: ChatItem) -> EffectiveSettings {
        let chatSettings = chat.notificationSettings
        let scope = scope(for: chat)
        let scopeSettings = self.scopeSettings[scope]

        let muteFor = chatSettings.useDefaultMuteFor
            ? (scopeSettings?.muteFor ?? 0)
            : chatSettings.muteFor
        let soundId = chatSettings.useDefaultSound
            ? (scopeSettings?.soundId ?? TdInt64(-1))
            : chatSettings.soundId
        let showPreview = chatSettings.useDefaultShowPreview
            ? (scopeSettings?.showPreview ?? true)
            : chatSettings.showPreview

        return EffectiveSettings(
            muteFor: muteFor,
            sound: soundId.rawValue != 0,
            showPreview: showPreview
        )
    }

    private func scope(for chat: ChatItem) -> NotificationSettingsScope {
        if chat.isChannel { return .notificationSettingsScopeChannelChats }
        if chat.isGroup { return .notificationSettingsScopeGroupChats }
        return .notificationSettingsScopePrivateChats
    }

    private struct EffectiveSettings {
        let muteFor: Int
        let sound: Bool
        let showPreview: Bool
    }
}

extension AppNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let chatId = (userInfo["chatId"] as? NSNumber)?.int64Value ?? (userInfo["chatId"] as? Int64)
        Task { @MainActor in
            if let chatId {
                AppNotifications.shared.pendingChatId = chatId
            }
            completionHandler()
        }
    }
}

/// Installs the notification center delegate before the app finishes launching.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppNotifications.shared.activate()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // Calls are portrait-only: the video stage and the top strip are laid
        // out for the book orientation.
        return .all
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        ImageCache.clear()
        CallDiag.log("memory warning: cleared image caches")
        ImageCache.clear()
    }
}
