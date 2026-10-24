import SwiftUI
import UIKit

@main
struct FignyagramApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
                BuiltInProxyManager.shared.refreshOnActivation()
                Task { await AppNotifications.shared.refreshSettings() }
            case .background:
                ImageCache.flushForBackground()
                URLCache.shared.removeAllCachedResponses()
                // Keep TDLib online while files are downloading; the background
                // task gives the OS time to finish the transfer.
                if TelegramClient.shared.activeDownloadCount == 0 {
                    TelegramClient.shared.setOnline(false)
                }
                // Keep music playing in the background; only stop the separate
                // voice-note player so it doesn't fight over the audio session.
                if MusicPlayer.shared.current == nil {
                    AudioPlayback.shared.stop()
                }
            default:
                break
            }
        }
    }
}
