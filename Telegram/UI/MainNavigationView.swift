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

    @AppStorage(DuoSimulationKeys.active) private var duoSimulationActive = false
    @AppStorage(DuoSimulationKeys.orientation) private var duoOrientation = DuoSimulationOrientation.portrait.rawValue
    @AppStorage(DuoSimulationKeys.foldWidth) private var duoFoldWidth = 10.0

    var body: some View {
        GeometryReader { geometry in
            Group {
                if useCompactLayout(for: geometry.size) {
                    compactRoot
                } else if duoSimulationActive {
                    simulatorShell
                } else {
                    splitRoot
                }
            }
            .sheet(isPresented: $showDeveloperHub) {
                DeveloperSettingsView()
            }
        }
    }

    /// Portrait phones/tablets (and the Duo simulator in portrait) always use the
    /// compact mobile shell; only a wide landscape window gets three panes.
    private func useCompactLayout(for size: CGSize) -> Bool {
        if duoSimulationActive {
            return duoOrientation == DuoSimulationOrientation.portrait.rawValue
        }
        if size.width < size.height { return true }
        return sizeClass == .compact
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

    /// Duo simulator: same three columns but stacked manually, so the fold line
    /// width from the developer hub is visible and adjustable on a real device.
    private var simulatorShell: some View {
        HStack(spacing: 0) {
            SidebarView(currentTab: $currentTab) {
                showDeveloperHub = true
            }
            .frame(width: 230)

            Divider()

            NavigationStack {
                contentColumn
            }
            .frame(width: 340)

            Rectangle()
                .fill(Color.black.opacity(0.65))
                .frame(width: CGFloat(duoFoldWidth))
                .accessibilityHidden(true)

            NavigationStack {
                detailColumn
            }
            .frame(maxWidth: .infinity)
        }
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
