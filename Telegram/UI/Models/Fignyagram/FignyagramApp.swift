import SwiftUI
import UIKit

@main
struct FignyagramApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("app_ui_refresh_trigger") private var uiRefreshTrigger = 0

    init() {
        ConsoleCapture.install()
        ImageCache.configureForDevice()
        _ = HardwareTuning.shared
        _ = ClassicDesignMode.shared
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Decoded thumbnails are only a cache: dropping them does not lose
            // messages or media on disk.
            ImageCache.clear()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(uiRefreshTrigger)
                .onOpenURL { url in
                    ShareInbox.shared.handle(url)
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                ShareInbox.shared.loadPending()
                TelegramClient.shared.start() // retry if launch happened before first unlock
                TelegramClient.shared.retryTdlibParametersIfNeeded()
                TelegramClient.shared.setOnline(true)
                Task { await TelegramClient.shared.enforceInvisibleIfNeeded() }
                BuiltInProxyManager.shared.refreshOnActivation()
                Task { await AppNotifications.shared.refreshSettings() }
            case .background:
                AppLock.shared.lockIfNeeded()
                ImageCache.flushForBackground()
                URLCache.shared.removeAllCachedResponses()
                // Keep TDLib online while files are downloading; the background
                // task gives the OS time to finish the transfer.
                if TelegramClient.shared.activeDownloadCount == 0 {
                    TelegramClient.shared.setOnline(false)
                }
                // Keep music playing in the background; only stop the separate
                // voice-note player so it doesn't fight over the audio session.
                let callIsActive = CallManager.shared.currentCall != nil || GroupCallManager.shared.isActive
                if MusicPlayer.shared.current == nil && !callIsActive {
                    AudioPlayback.shared.stop()
                }
                if callIsActive {
                    CallDiag.log("app entered background during a call: keeping audio session")
                }
            default:
                break
            }
        }
    }
}
