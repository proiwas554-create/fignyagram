import SwiftUI
import TDLibKit

/// Top-level sections of the Duo shell.
enum DuoTab: String, CaseIterable, Identifiable {
    case chats
    case music
    case news

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Чаты"
        case .music: return "Музыка"
        case .news: return "Новости"
        }
    }

    var icon: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .music: return "music.note"
        case .news: return "newspaper"
        }
    }
}

/// Three-column desktop shell (iPad / Mac Catalyst) that collapses into the
/// classic compact `TabView` on iPhone-sized screens.
@available(iOS 16.0, *)
struct MainNavigationView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var currentTab: DuoTab = .chats
    @State private var selectedChat: ChatTarget?
    @State private var showDeveloperHub = false

    var body: some View {
        Group {
            if sizeClass == .compact {
                compactRoot
            } else {
                splitRoot
            }
        }
        .sheet(isPresented: $showDeveloperHub) {
            DeveloperSettingsView()
        }
    }

    // MARK: - Compact (iPhone)

    private var compactRoot: some View {
        TabView {
            ChatListView()
                .tabItem { Label(DuoTab.chats.title, systemImage: DuoTab.chats.icon) }
            MusicView()
                .tabItem { Label(DuoTab.music.title, systemImage: DuoTab.music.icon) }
            NewsFeedView()
                .tabItem { Label(DuoTab.news.title, systemImage: DuoTab.news.icon) }
        }
    }

    // MARK: - Regular (iPad / Mac)

    private var splitRoot: some View {
        NavigationSplitView {
            SidebarView(currentTab: $currentTab) {
                showDeveloperHub = true
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } content: {
            NavigationStack {
                contentColumn
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
        } detail: {
            NavigationStack {
                detailColumn
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch currentTab {
        case .chats:
            ChatListView(splitSelection: $selectedChat)
        case .music:
            MusicView()
        case .news:
            NewsFeedView()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch currentTab {
        case .chats:
            if let chat = selectedChat {
                ChatConversationView(chat: chat)
                    .id(chat.chatId)
            } else {
                DuoPlaceholder(
                    icon: "bubble.left.and.bubble.right",
                    title: "Выберите чат для начала общения"
                )
            }
        case .music:
            DuoPlaceholder(
                icon: "music.note",
                title: "Плеер откроется из вкладки «Музыка»"
            )
        case .news:
            DuoPlaceholder(
                icon: "newspaper",
                title: "Выберите материал в ленте"
            )
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var currentTab: DuoTab
    let onOpenDeveloper: () -> Void

    @ObservedObject private var developer = DeveloperMode.shared
    @ObservedObject private var client = TelegramClient.shared

    var body: some View {
        List {
            Section {
                ForEach(DuoTab.allCases) { tab in
                    Button {
                        currentTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .font(.system(size: 13, weight: currentTab == tab ? .semibold : .regular))
                            .foregroundColor(currentTab == tab ? .accentColor : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        currentTab == tab ? Color.accentColor.opacity(0.12) : Color.clear
                    )
                }
            } header: {
                Text("FIGNYAGRAM")
            }

            Section {
                Button {
                    onOpenDeveloper()
                } label: {
                    Label("Разработчик", systemImage: "hammer")
                }
                .buttonStyle(.plain)
                .foregroundColor(developer.isUnlocked ? .accentColor : .secondary)
            } header: {
                Text("ОТЛАДКА")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Fignyagram")
        .safeAreaInset(edge: .bottom) {
            if let me = client.me {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(me.firstName.isEmpty ? "Аккаунт" : me.firstName)
                            .font(.appFootnote)
                            .lineLimit(1)
                        if let username = me.usernames?.activeUsernames.first, !username.isEmpty {
                            Text("@\(username)")
                                .font(.appCaption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Empty detail

struct DuoPlaceholder: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundColor(.secondary)
            Text(title)
                .font(.appFootnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
