#if targetEnvironment(simulator)
import SwiftUI

/// Debug-only entrance for simulators where TDLib's OpenSSL aborts on TLS.
/// Never compiled into device builds.
enum SimulatorBypass {
    static let key = "simBypassAuth"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }
    static func enable() { UserDefaults.standard.set(true, forKey: key) }
}

struct SimulatorMockChat: Identifiable, Hashable {
    let id: Int64
    let title: String
    let preview: String
    let unread: Int
    let pinned: Bool
}

struct SimulatorMockRoot: View {
    @State private var visible = 10
    @State private var showDeveloper = false
    @State private var taps = 0

    private let chats: [SimulatorMockChat] = (1...12).map { index in
        SimulatorMockChat(id: Int64(index),
                          title: index == 1 ? "@fignyagram" : "Fignyagram Test \(index)",
                          preview: index == 1 ? "Добро пожаловать в Fignyagram" : "Сообщение \(index)",
                          unread: index % 3,
                          pinned: index == 1)
    }

    var body: some View {
        List {
            ForEach(chats.prefix(visible)) { chat in
                HStack(spacing: 10) {
                    Circle().fill(Color.accentColor.opacity(0.25))
                        .frame(width: 36, height: 36)
                        .overlay(Text(String(chat.title.prefix(1))).font(.headline))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if chat.pinned { Image(systemName: "pin.fill").font(.caption2) }
                            Text(chat.title).font(.body.weight(.semibold)).lineLimit(1)
                            Spacer()
                            if chat.unread > 0 {
                                Text("\(chat.unread)").font(.caption2.bold())
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor))
                                    .foregroundColor(.white)
                            }
                        }
                        Text(chat.preview).font(.footnote).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
            if chats.count > visible {
                Button {
                    visible += 10
                } label: {
                    Text(L10n.t("ChatList.ShowMore")).frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Fignyagram")
        .navigationBarTitleDisplayMode(.large)
        .simultaneousGesture(TapGesture(count: 10).onEnded {
            DeveloperMode.shared.unlock()
            showDeveloper = true
        })
        .sheet(isPresented: $showDeveloper) { DeveloperSettingsView() }
    }
}
#endif
