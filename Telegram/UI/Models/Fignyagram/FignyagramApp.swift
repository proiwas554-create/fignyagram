import SwiftUI

@main
struct FignyagramApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onDisappear {
                    TelegramClient.shared.close()
                }
        }
    }
}
