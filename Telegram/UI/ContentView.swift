import SwiftUI

struct ContentView: View {
    @ObservedObject private var client = TelegramClient.shared

    var body: some View {
        Group {
            if client.isAuthorized {
                ChatListView()
            } else {
                AuthView()
            }
        }
        .onAppear { client.start() }
    }
}

#Preview {
    ContentView()
}
