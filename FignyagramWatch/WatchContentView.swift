import SwiftUI

struct WatchContentView: View {
    @StateObject private var bridge = WatchBridgeManager.shared
    @State private var visible = 10

    var body: some View {
        NavigationView {
            List {
                ForEach(bridge.chats) { chat in
                    NavigationLink(destination: WatchChatDetailPlaceholder(chat: chat)) {
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

struct WatchChatDetailPlaceholder: View {
    let chat: WatchChat
    var body: some View {
        VStack {
            Text(chat.title).font(.headline)
            Text(L10n.t("Watch.DetailSoon")).font(.footnote).foregroundColor(.secondary)
        }
    }
}

enum L10n {
    static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }
}
