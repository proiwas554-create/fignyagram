import Combine
import Foundation
import SwiftUI
import TDLibKit

/// A single feed entry: one channel post plus the context needed to render it.
struct NewsFeedPost: Identifiable, Equatable {
    let message: TDLibKit.Message
    let chatTitle: String

    /// Message ids are unique per chat, so the pair is the feed identity.
    var id: String { "\(message.chatId):\(message.id)" }

    var date: Foundation.Date { Foundation.Date(timeIntervalSince1970: TimeInterval(message.date)) }
    var viewCount: Int { message.interactionInfo?.viewCount ?? 0 }
    var forwardCount: Int { message.interactionInfo?.forwardCount ?? 0 }
    var replyCount: Int { message.interactionInfo?.replyInfo?.replyCount ?? 0 }

    var reactionCount: Int {
        message.interactionInfo?.reactions?.reactions.reduce(0) { $0 + $1.totalCount } ?? 0
    }

    /// Engagement score with a time decay so old viral posts do not dominate.
    func engagementScore(now: Foundation.Date = Foundation.Date()) -> Double {
        let base = Double(viewCount) + Double(reactionCount) * 3.0
            + Double(forwardCount) * 2.0 + Double(replyCount) * 1.5
        let ageHours = max(1.0, now.timeIntervalSince(date) / 3600.0)
        // Soft decay: a 24h-old post keeps roughly a third of its weight.
        return base / pow(1.0 + ageHours / 12.0, 0.8)
    }
}

/// News feed data layer.
///
/// The original Telegram-iOS reads channel posts through Postbox
/// (`PostboxView` / `Transaction`). This fork has no Postbox: the local store
/// (`ChatStore`) already keeps every chat together with its `lastMessage`, and
/// TDLibKit exposes `getChatHistory` for the per-channel slices. This manager
/// combines both sources into one feed and keeps the rest of the app untouched.
@MainActor
final class NewsFeedDataManager: ObservableObject {
    enum Tab: String, CaseIterable {
        case added
        case forYou
        case important

        /// Localized tab title; the case itself is the stable identifier.
        var title: String {
            switch self {
            case .added: return L10n.t("Feed.Tab.Added")
            case .forYou: return L10n.t("Feed.Tab.ForYou")
            case .important: return L10n.t("Feed.Tab.Important")
            }
        }
    }

    enum Sorting {
        /// Newest first, like the «Добавленные» tab.
        case recent
        /// Weighted by views/reactions/forwards with a time decay.
        case engagement
    }

    static let shared = NewsFeedDataManager()

    @Published private(set) var posts: [NewsFeedPost] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published var tab: Tab = .added
    @Published var sorting: Sorting = .recent

    /// Tuning knobs, kept here so the UI never hard-codes the limits.
    @AppStorage("feedPostsPerChannel") var configuredPostsPerChannel = 0
    @AppStorage("feedMaxPosts") var configuredMaxPosts = 0
    @AppStorage("feedShowForYou") var showForYouTab = true
    @AppStorage("feedShowImportant") var showImportantTab = true
    @AppStorage("feedAutoRefreshSeconds") var autoRefreshSeconds = 0

    var postsPerChannel: Int {
        if configuredPostsPerChannel > 0 { return configuredPostsPerChannel }
        return DevicePerformance.isLowMemory ? 5 : 8
    }
    var maximumChannels = DevicePerformance.isLowMemory ? 60 : 150
    var maximumPosts: Int {
        if configuredMaxPosts > 0 { return configuredMaxPosts }
        return DevicePerformance.isLowMemory ? 200 : 400
    }
    /// Concurrent history requests: TDLib handles a few in parallel well.
    var historyConcurrency = DevicePerformance.isLowMemory ? 3 : 6
    /// Number of posts the «Для вас» tab keeps after ranking.
    var recommendationsCount = 60

    /// Optional hook for the local AI filter (AIAgentService in the app).
    /// It receives feed candidates and returns the ids that should stay.
    var recommendationFilter: (([NewsFeedPost]) async -> [String]?)?

    private var lastLoad: Foundation.Date?
    private let minimumReloadInterval: TimeInterval = 60

    // MARK: - Public API

    func refresh(force: Bool = false) async {
        if !force, let lastLoad, Foundation.Date().timeIntervalSince(lastLoad) < minimumReloadInterval {
            return
        }
        guard !isLoading else { return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let channels = subscribedChannels()
        guard !channels.isEmpty else {
            posts = []
            lastLoad = Foundation.Date()
            return
        }

        var collected: [String: NewsFeedPost] = [:]
        var index = 0
        while index < channels.count {
            let slice = Array(channels[index..<min(index + historyConcurrency, channels.count)])
            index += historyConcurrency
            await withTaskGroup(of: [NewsFeedPost].self) { group in
                for chat in slice {
                    group.addTask { [postsPerChannel] in
                        await Self.fetchPosts(chat: chat, limit: postsPerChannel)
                    }
                }
                for await batch in group {
                    for post in batch {
                        collected[post.id] = post
                    }
                }
            }
        }

        let merged = Array(collected.values)
        lastLoad = Foundation.Date()
        sortAndPublish(merged)
    }

    /// Re-applies sorting/ranking without hitting the network.
    func reapplySorting() {
        sortAndPublish(posts)
    }

    // MARK: - Selection

    private func subscribedChannels() -> [ChatItem] {
        ChatStore.shared.chats.values
            .filter { chat in
                // Public subscription channels only; groups, bots and Saved
                // Messages are not part of the news feed.
                guard chat.isChannel else { return false }
                return !Self.isSavedMessages(chat.id)
            }
            .sorted { ($0.lastMessage?.date ?? 0) > ($1.lastMessage?.date ?? 0) }
            .prefix(maximumChannels)
            .map { $0 }
    }

    private static func isSavedMessages(_ chatId: Int64) -> Bool {
        // Saved Messages has the same id as the current user; the store marks it
        // separately, so fall back to the well-known check used by the UI.
        chatId == ChatStore.shared.lastOpenedChatId ? false : chatId == 0
    }

    private static func fetchPosts(chat: ChatItem, limit: Int) async -> [NewsFeedPost] {
        guard let client = TelegramClient.shared.tdClient else { return [] }
        do {
            let history = try await client.getChatHistory(chatId: chat.id,
                                                          fromMessageId: 0,
                                                          limit: limit,
                                                          offset: 0,
                                                          onlyLocal: false)
            return (history.messages ?? [])
                .filter { !$0.isOutgoing }
                .map { NewsFeedPost(message: $0, chatTitle: chat.title) }
        } catch {
            CallDiag.log("news feed: history failed chat=\(chat.id) error=\(error)")
            return []
        }
    }

    // MARK: - Ranking

    private func sortAndPublish(_ source: [NewsFeedPost]) {
        let stopWords = Self.stopWords()
        let source = stopWords.isEmpty ? source : source.filter { post in
            let text = Self.plainText(of: post.message).lowercased()
            return !stopWords.contains { text.contains($0) }
        }
        let sorted: [NewsFeedPost]
        switch tab {
        case .added:
            switch sorting {
            case .recent:
                sorted = source.sorted { (lhs: NewsFeedPost, rhs: NewsFeedPost) in lhs.date > rhs.date }
            case .engagement:
                sorted = source.sorted { (lhs: NewsFeedPost, rhs: NewsFeedPost) in lhs.engagementScore() > rhs.engagementScore() }
            }
        case .forYou:
            sorted = rankedForYou(source)
        case .important:
            let triggers = Self.importantKeywords()
            sorted = triggers.isEmpty ? [] : source.filter { post in
                let text = Self.plainText(of: post.message).lowercased()
                return triggers.contains { text.contains($0) }
            }
        }
        posts = Array(sorted.prefix(maximumPosts))
    }

    private func rankedForYou(_ source: [NewsFeedPost]) -> [NewsFeedPost] {
        let interests = Self.interestKeywords()
        let scored = source.map { post -> (NewsFeedPost, Double) in
            var score = post.engagementScore()
            if !interests.isEmpty {
                let text = Self.plainText(of: post.message).lowercased()
                let hits = interests.reduce(0) { partial, keyword in
                    text.contains(keyword) ? partial + 1 : partial
                }
                score *= 1.0 + Double(hits) * 0.35
            }
            return (post, score)
        }
        return scored
            .sorted { (lhs: (NewsFeedPost, Double), rhs: (NewsFeedPost, Double)) in lhs.1 > rhs.1 }
            .prefix(recommendationsCount)
            .map { $0.0 }
    }

    static func stopWords() -> [String] {
        keywords(forKey: "newsFeedStopWords")
    }

    static func importantKeywords() -> [String] {
        keywords(forKey: "newsFeedImportantWords")
    }

    private static func keywords(forKey key: String) -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    func clearCachedPosts() {
        posts = []
    }

    private static func interestKeywords() -> [String] {
        (UserDefaults.standard.string(forKey: "newsFeedInterests") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func plainText(of message: TDLibKit.Message) -> String {
        if case .messageText(let text) = message.content { return text.text.text }
        return ""
    }
}


// MARK: - Feed UI

import SwiftUI


/// News feed: «Добавленные» (subscription channels) and «Для вас» (ranked).
/// Posts are rendered read-only with the same row the chat list uses, so media,
/// formatting and inline reactions look identical to normal messages.
struct NewsFeedView: View {
    @ObservedObject private var manager = NewsFeedDataManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: NewsFeedDataManager.Tab = .added
    @State private var showFilters = false
    @State private var showSettings = false
    @AppStorage("feedShowForYou") private var showForYouTab = true
    @AppStorage("feedShowImportant") private var showImportantTab = true
    @AppStorage("feedAutoRefreshSeconds") private var autoRefreshSeconds = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(NewsFeedDataManager.Tab.added.title).tag(NewsFeedDataManager.Tab.added)
                    if showForYouTab {
                        Text(NewsFeedDataManager.Tab.forYou.title).tag(NewsFeedDataManager.Tab.forYou)
                    }
                    if showImportantTab {
                        Text(NewsFeedDataManager.Tab.important.title).tag(NewsFeedDataManager.Tab.important)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if manager.isLoading && manager.posts.isEmpty {
                    Spacer()
                    ProgressView(NSLocalizedString("Generated.2d248779c2b9", comment: ""))
                    Spacer()
                } else if manager.posts.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "newspaper")
                            .font(.system(size: 34))
                            .foregroundColor(.secondary)
                        Text(L10n.t("Auto.28b9b1f2ba"))
                            .font(.appBody)
                        Text(L10n.t("Auto.85289b9129"))
                            .font(.appFootnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(manager.posts) { post in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(post.chatTitle)
                                        .font(.appCaption.bold())
                                        .lineLimit(1)
                                    Spacer()
                                    Text(Self.dateText(post.date))
                                        .font(.appCaption)
                                        .foregroundColor(.secondary)
                                }
                                MessageRow(
                                    message: post.message,
                                    showSender: false,
                                    isRead: true,
                                    senderName: post.chatTitle,
                                    forwardedFrom: nil
                                )
                            }
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await manager.refresh(force: true) }
                }
            }
            .navigationTitle(L10n.t("Auto.69df1f85b0"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    Button { showFilters = true } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    Menu {
                        Button(L10n.t("Auto.ea5256005b")) {
                            manager.sorting = .recent
                            manager.reapplySorting()
                        }
                        Button(L10n.t("Auto.f196723646")) {
                            manager.sorting = .engagement
                            manager.reapplySorting()
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                NewsFeedFiltersView()
            }
            .sheet(isPresented: $showSettings) {
                NewsFeedSettingsView()
            }
            .task(id: autoRefreshSeconds) {
                guard autoRefreshSeconds > 0 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(autoRefreshSeconds) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await manager.refresh(force: true)
                }
            }
            .task {
                manager.tab = tab
                await manager.refresh()
            }
            .onChange(of: tab) { value in
                manager.tab = value
                manager.reapplySorting()
            }
        }
        .navigationViewStyle(.stack)
    }

    private static func dateText(_ date: Foundation.Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMM, HH:mm")
        return formatter.string(from: date)
    }
}


/// Stop-words / important-words editor for the news feed.
struct NewsFeedFiltersView: View {
    @AppStorage("newsFeedStopWords") private var stopWords = ""
    @AppStorage("newsFeedImportantWords") private var importantWords = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Feed.StopWords")) {
                    TextEditor(text: $stopWords)
                        .frame(minHeight: 90)
                        .font(.appBody)
                }
                Section(L10n.t("Feed.ImportantWords")) {
                    TextEditor(text: $importantWords)
                        .frame(minHeight: 90)
                        .font(.appBody)
                }
                Section {
                    Text(L10n.t("Feed.FiltersHint"))
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("Feed.Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}


/// News feed preferences: limits, tabs and refresh cadence.
struct NewsFeedSettingsView: View {
    @ObservedObject private var manager = NewsFeedDataManager.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("feedPostsPerChannel") private var postsPerChannel = 0
    @AppStorage("feedMaxPosts") private var maxPosts = 0
    @AppStorage("feedShowForYou") private var showForYou = true
    @AppStorage("feedShowImportant") private var showImportant = true
    @AppStorage("feedAutoRefreshSeconds") private var autoRefresh = 0

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Feed.Settings.Content")) {
                    Picker(L10n.t("Feed.Settings.PerChannel"), selection: $postsPerChannel) {
                        Text(L10n.t("Feed.Settings.Auto")).tag(0)
                        Text("5").tag(5); Text("8").tag(8); Text("12").tag(12); Text("20").tag(20)
                    }
                    Picker(L10n.t("Feed.Settings.MaxPosts"), selection: $maxPosts) {
                        Text(L10n.t("Feed.Settings.Auto")).tag(0)
                        Text("200").tag(200); Text("400").tag(400); Text("800").tag(800)
                    }
                }
                Section(L10n.t("Feed.Settings.Tabs")) {
                    Toggle(L10n.t("Feed.Tab.ForYou"), isOn: $showForYou)
                    Toggle(L10n.t("Feed.Tab.Important"), isOn: $showImportant)
                }
                Section(L10n.t("Feed.Settings.Refresh")) {
                    Picker(L10n.t("Feed.Settings.RefreshInterval"), selection: $autoRefresh) {
                        Text(L10n.t("Settings.Never")).tag(0)
                        Text("1 min").tag(60)
                        Text("5 min").tag(300)
                        Text("15 min").tag(900)
                    }
                }
                Section {
                    NavigationLink(L10n.t("Feed.Filters")) { NewsFeedFiltersView() }
                    Text(L10n.t("Feed.Settings.Hint"))
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("Feed.Settings.Title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
