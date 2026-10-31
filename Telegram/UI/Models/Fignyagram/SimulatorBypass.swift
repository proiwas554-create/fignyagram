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
    enum Pane: Equatable { case none, chat(Int64), settings, developer }

    @State private var pane: Pane = .none
    @State private var visible = 10
    @State private var taps = 0
    @State private var translated = false

    private let chats: [SimulatorMockChat] = (1...12).map { index in
        SimulatorMockChat(id: Int64(index),
                          title: index == 1 ? "@fignyagram" : "Fignyagram Test \(index)",
                          preview: index == 1 ? "Welcome to Fignyagram" : "Message \(index)",
                          unread: index % 3,
                          pinned: index == 1)
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPanel.frame(width: 360).background(Color(.systemBackground))
            Divider()
            rightPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var leftPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fignyagram")
                    .font(.title2.weight(.bold))
                    .onTapGesture {
                        taps += 1
                        if taps >= 10 { taps = 0; pane = .developer }
                    }
                Spacer()
                Button { pane = .settings } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            List {
                ForEach(chats.prefix(visible)) { chat in
                    Button {
                        pane = .chat(chat.id)
                    } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Color.accentColor.opacity(0.25))
                                .frame(width: 34, height: 34)
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
                                Text(chat.preview).font(.footnote)
                                    .foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if chats.count > visible {
                    Button { visible += 10 } label: {
                        Text(L10n.t("ChatList.ShowMore")).frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var rightPanel: some View {
        switch pane {
        case .none:
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 52))
                    .foregroundColor(.accentColor)
                Text("Fignyagram for Duo").font(.title3.weight(.semibold))
                Text("Выберите чат слева").foregroundColor(.secondary)
                Text(L10n.t("Proxy.SimulatorDirect")).font(.footnote).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
        case .chat(let id):
            SimulatorMockChatView(chatId: id, title: chats.first { $0.id == id }?.title ?? "")
        case .settings:
            SettingsView()
        case .developer:
            DeveloperSettingsView()
        }
    }
}

struct SimulatorMockChatView: View {
    let chatId: Int64
    let title: String
    @State private var translated = false

    private struct MockMessage: Identifiable {
        let id: Int
        let text: String
        let russian: String
        let outgoing: Bool
    }

    private let messages: [MockMessage] = [
        .init(id: 1, text: "Welcome to Fignyagram!", russian: "Добро пожаловать в Fignyagram!", outgoing: false),
        .init(id: 2, text: "This build runs on the Duo simulator.", russian: "Эта сборка работает на симуляторе Duo.", outgoing: false),
        .init(id: 3, text: "Проверяем пузыри сообщений.", russian: "Проверяем пузыри сообщений.", outgoing: true),
        .init(id: 4, text: "Die Übersetzung läuft im Hintergrund.", russian: "Перевод работает в фоне.", outgoing: false),
        .init(id: 5, text: "Scroll should be silky smooth.", russian: "Скролл должен быть идеально плавным.", outgoing: false),
        .init(id: 6, text: "Пасхалка: 10 тапов по заголовку.", russian: "Пасхалка: 10 тапов по заголовку.", outgoing: true),
        .init(id: 7, text: "Translation is cached locally.", russian: "Перевод кэшируется локально.", outgoing: false),
        .init(id: 8, text: "Настройки открываются справа.", russian: "Настройки открываются справа.", outgoing: true),
        .init(id: 9, text: "Pinned channel @fignyagram stays on top.", russian: "Закреплённый канал @fignyagram остаётся сверху.", outgoing: false)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(translated ? "Оригинал" : "Перевести") { withAnimation { translated.toggle() } }
            }
            .padding()
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        HStack {
                            if message.outgoing { Spacer(minLength: 60) }
                            Text(translated ? message.russian : message.text)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(message.outgoing ? Color.accentColor : Color(.tertiarySystemBackground))
                                )
                                .foregroundColor(message.outgoing ? .white : .primary)
                            if !message.outgoing { Spacer(minLength: 60) }
                        }
                    }
                }
                .padding()
            }
        }
    }
}
#endif
