import SwiftUI

struct WatchContentView: View {
    @StateObject private var bridge = WatchBridgeManager.shared
    @State private var visible = 10

    var body: some View {
        #if targetEnvironment(simulator)
        TabView {
            chatTab
            List { ForEach(["Fignyagram Theme", "Night Drive", "Deep Focus"], id: \.self) { Text($0) } }
                .navigationTitle("Музыка")
            List { ForEach(["Fignyagram 1.0 beta", "Duo Split-View", "Перевод на лету"], id: \.self) { Text($0) } }
                .navigationTitle("Новости")
        }
        .onAppear {
            bridge.activate()
            bridge.requestChats(limit: visible)
        }
        #else
        chatTab
        #endif
    }

    private var chatTab: some View {
        NavigationView {
            List {
                ForEach(bridge.chats) { chat in
                    NavigationLink(destination: WatchChatView(chat: chat)) {
                        WatchChatRowView(chat: chat)
                    }
                }
                if bridge.totalChats > visible {
                    Button {
                        visible += 10
                        bridge.requestChats(limit: visible)
                    } label: {
                        Text(L10n.t("Watch.ShowMore"))
                            .font(.footnote)
                    }
                }
                if bridge.chats.isEmpty {
                    Text(bridge.lastError ?? L10n.t("Watch.Empty"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Fignyagram")
        }
        .onAppear {
            bridge.activate()
            bridge.requestChats(limit: visible)
        }
    }
}

enum L10n {
    static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}
