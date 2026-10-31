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

protocol DuoContentProvider {
    var chats: [SimulatorMockChat] { get }
    var tracks: [String] { get }
    var news: [(title: String, body: String)] { get }
}

struct SimulatorMockProvider: DuoContentProvider {
    let chats: [SimulatorMockChat] = (1...12).map { index in
        SimulatorMockChat(id: Int64(index),
                          title: index == 1 ? "@fignyagram" : "Fignyagram Test \(index)",
                          preview: index == 1 ? "Welcome to Fignyagram" : "Message \(index)",
                          unread: index % 3,
                          pinned: index == 1)
    }
    let tracks = ["Fignyagram Theme", "Night Drive", "Deep Focus", "Signal"]
    let news: [(title: String, body: String)] = [
        ("Fignyagram 1.0 beta", "Многовкладочный интерфейс Duo готов: чаты, музыка и новости в одном окне."),
        ("Duo Split-View", "Сайдбар 320 pt, безопасные отступы от сгиба, настройки в нативном toolbar."),
        ("Перевод на лету", "Строки кэшируются локально, пузыри обновляются без перезагрузки списка.")
    ]
}

struct SimulatorMockRoot: View {
    enum Pane: Hashable { case chat(Int64), settings, developer }
    enum Tab { case chats, music, news }

    private let provider: DuoContentProvider = SimulatorMockProvider()

    @State private var tab: Tab = .chats
    @State private var pane: Pane = .chat(1)
    @State private var visible = 10
    @State private var selectedTrack = 0
    @State private var selectedNews = 0
    @State private var taps = 0

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let wide = geo.size.width > 600 && landscape
            if wide {
                HStack(spacing: 0) {
                    sidebar.frame(width: 320).background(Color(.systemBackground))
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.secondarySystemBackground))
                }
            } else {
                TabView(selection: $tab) {
                    NavigationView { compactChats }.tabItem {
                        Label(L10n.t("Auto.19adecc3d1"), systemImage: "bubble.left.and.bubble.right")
                    }.tag(Tab.chats)
                    NavigationView { compactMusic }.tabItem {
                        Label(L10n.t("Auto.0660a7580a"), systemImage: "music.note")
                    }.tag(Tab.music)
                    NavigationView { compactNews }.tabItem {
                        Label(L10n.t("Feed.Tab.Title"), systemImage: "newspaper")
                    }.tag(Tab.news)
                }
            }
        }
    }

    // MARK: sidebar (iPad style)

    private var sidebar: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(L10n.t("Auto.19adecc3d1")).tag(Tab.chats)
                    Text(L10n.t("Auto.0660a7580a")).tag(Tab.music)
                    Text(L10n.t("Feed.Tab.Title")).tag(Tab.news)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12).padding(.top, 6)
                sidebarContent
            }
            .navigationTitle("Fignyagram")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { pane = .settings } label: { Image(systemName: "gearshape") }
                }
            }
            .onTapGesture {
                taps += 1
                if taps >= 10 { taps = 0; pane = .developer }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        switch tab {
        case .chats:
            List {
                ForEach(provider.chats.prefix(visible)) { chat in
                    Button { pane = .chat(chat.id) } label: { row(chat) }
                        .buttonStyle(.plain)
                }
                if provider.chats.count > visible {
                    Button { visible += 10 } label: {
                        Text(String(format: L10n.t("ChatList.ShowMore"), 10)).frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.plain)
        case .music:
            List(provider.tracks.indices, id: \.self) { index in
                Button {
                    selectedTrack = index
                } label: {
                    HStack {
                        Image(systemName: selectedTrack == index ? "speaker.wave.2.fill" : "music.note")
                        Text(provider.tracks[index])
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        case .news:
            List(provider.news.indices, id: \.self) { index in
                Button { selectedNews = index } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.news[index].title).font(.headline)
                        Text(provider.news[index].body).font(.footnote)
                            .foregroundColor(.secondary).lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    // MARK: compact (iPhone style)

    private var compactChats: some View {
        List {
            ForEach(provider.chats.prefix(visible)) { chat in
                NavigationLink(destination: SimulatorMockChatView(chatId: chat.id,
                                                                  title: chat.title,
                                                                  embedded: false)) {
                    row(chat)
                }
            }
            if provider.chats.count > visible {
                Button { visible += 10 } label: {
                    Text(String(format: L10n.t("ChatList.ShowMore"), 10)).frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Fignyagram")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { pane = .settings } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: Binding(get: { pane == .settings },
                                    set: { if !$0 { pane = .chat(1) } })) {
            SettingsView()
        }
    }

    private var compactMusic: some View {
        List {
            ForEach(provider.tracks.indices, id: \.self) { index in
                HStack {
                    Image(systemName: "music.note")
                    Text(provider.tracks[index])
                }
            }
        }
        .navigationTitle(L10n.t("Auto.0660a7580a"))
    }

    private var compactNews: some View {
        List {
            ForEach(provider.news.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.news[index].title).font(.headline)
                    Text(provider.news[index].body).font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(L10n.t("Feed.Tab.Title"))
    }

    private func row(_ chat: SimulatorMockChat) -> some View {
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
                Text(chat.preview).font(.footnote).foregroundColor(.secondary).lineLimit(1)
            }
        }
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .music:
            VStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .purple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 240, height: 240)
                    .overlay(Image(systemName: "music.note").font(.system(size: 64)).foregroundColor(.white))
                Text(provider.tracks[selectedTrack]).font(.title2.weight(.semibold))
                HStack(spacing: 36) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "play.fill").font(.system(size: 34))
                    Image(systemName: "forward.fill")
                }
                .foregroundColor(.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .news:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(provider.news[selectedNews].title).font(.largeTitle.weight(.bold))
                    Text(provider.news[selectedNews].body).font(.body)
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
        case .chats:
            chatsDetail
        }
    }

    @ViewBuilder
    private var chatsDetail: some View {
        switch pane {
        case .chat(let id):
            SimulatorMockChatView(chatId: id,
                                  title: provider.chats.first { $0.id == id }?.title ?? "",
                                  embedded: true)
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
    var embedded: Bool = false
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
                if embedded {
                    Text(title).font(.headline)
                    Spacer()
                }
                Button(translated ? "Оригинал" : "Перевести") {
                    withAnimation(.easeInOut(duration: 0.2)) { translated.toggle() }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { message in
                        HStack {
                            if message.outgoing { Spacer(minLength: 80) }
                            Text(translated ? message.russian : message.text)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(message.outgoing ? Color.accentColor : Color(.tertiarySystemBackground))
                                )
                                .foregroundColor(message.outgoing ? .white : .primary)
                                .frame(maxWidth: 520, alignment: message.outgoing ? .trailing : .leading)
                            if !message.outgoing { Spacer(minLength: 80) }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
        .navigationTitle(embedded ? "" : title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
