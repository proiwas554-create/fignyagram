import Combine
import Foundation
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
        case added = "Добавленные"
        case forYou = "Для вас"
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
    var postsPerChannel = DevicePerformance.isLowMemory ? 5 : 8
    var maximumChannels = DevicePerformance.isLowMemory ? 60 : 150
    var maximumPosts = DevicePerformance.isLowMemory ? 200 : 400
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

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(NewsFeedDataManager.Tab.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if manager.isLoading && manager.posts.isEmpty {
                    Spacer()
                    ProgressView("Собираем ленту…")
                    Spacer()
                } else if manager.posts.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "newspaper")
                            .font(.system(size: 34))
                            .foregroundColor(.secondary)
                        Text("Пока нет постов")
                            .font(.appBody)
                        Text("Подпишитесь на каналы — их публикации появятся здесь.")
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
            .navigationTitle("Новости")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Сначала новые") {
                            manager.sorting = .recent
                            manager.reapplySorting()
                        }
                        Button("По вовлечённости") {
                            manager.sorting = .engagement
                            manager.reapplySorting()
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
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
