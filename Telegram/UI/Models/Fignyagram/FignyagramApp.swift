import SwiftUI

@main
struct FignyagramApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                TelegramClient.shared.setOnline(true)
            case .background:
                TelegramClient.shared.setOnline(false)
                AudioPlayback.shared.stop()
            default:
                break
            }
        }
    }
}
