import SwiftUI
import UIKit
import TDLibKit

struct PeerInfoView: View {
    let chatId: Int64

    @Environment(\.dismiss) private var dismiss
    @State private var info: TelegramClient.PeerInfo?
    @State private var isLoading = true
    @State private var taggedChatId: Int64?
    @State private var showEditor = false
    @State private var localAlias = ""
    @State private var showMembers = false
    @State private var showLinkedChat = false
    @State private var showDirectMessages = false
    @State private var showMyTag = false
    @State private var myTag = ""
    @State private var avatarViewer: AvatarViewerPayload?
    @State private var showAvatarError = false
    @State private var showLeaveConfirm = false
    @State private var showGifts = false

    @State private var memberTag: TelegramClient.MemberTagInfo?
    @ObservedObject private var aliases = LocalAliases.shared

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Загрузка…")
                } else if let info {
                    ScrollView {
                        VStack(spacing: 16) {
                            Button {
                                Task {
                                    var photos = await TelegramClient.shared.avatarPhotos(chatId: chatId)
                                    if photos.isEmpty, let big = info.photo?.big {
                                        photos = [AvatarPhoto(id: Int(big.id), file: big)]
                                    }
                                    if photos.isEmpty {
                                        showAvatarError = true
                                    } else {
                                        avatarViewer = AvatarViewerPayload(
                                            photos: photos,
                                            title: aliases.chatAlias(chatId) ?? info.title
                                        )
                                    }
                                }
                            } label: {
                                AvatarView(id: chatId, title: info.title, photo: info.photo, size: 92)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 16)

                            VStack(spacing: 4) {
                                Text(aliases.chatAlias(chatId) ?? info.title)
                                    .font(.title3.bold())
                                    .multilineTextAlignment(.center)
                                Text(info.typeText)
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }

                            if let username = info.username {
                                HStack(spacing: 6) {
                                    Text("@\(username)")
                                        .font(.appSubheadline)
                                        .foregroundColor(.accentColor)
                                    Button {
                                        UIPasteboard.general.string = "@\(username)"
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.t("Auto.670bd1660c"))
                                }
                            }

                            if let phone = info.phone {
                                HStack(spacing: 6) {
                                    Image(systemName: "phone")
                                    Text(phone)
                                    Button {
                                        UIPasteboard.general.string = phone
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.t("Auto.3ffc17563e"))
                                }
                                .font(.appFootnote)
                                .foregroundColor(.secondary)
                            }

                            if let count = info.memberCount {
                                Text(String(format: L10n.t("AutoI.82e6a2dead"), String(describing: count)))
                                    .font(.appFootnote)
                                    .foregroundColor(.secondary)
                            }

                            if let memberTag, !memberTag.text.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "tag")
                                    Text(memberTag.text)
                                        .foregroundColor(memberTag.isAdmin ? .green : .secondary)
                                    Button {
                                        UIPasteboard.general.string = memberTag.text
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.t("Auto.b447298c5b"))
                                }
                                .font(.appFootnote)
                            }

                            if let userId = info.userId,
                               userId != TelegramClient.shared.me?.id {
                                HStack(spacing: 0) {
                                    profileAction("Позвонить", icon: "phone") {
                                        TelegramClient.shared.callUser(userId: userId, isVideo: false)
                                        dismiss()
                                    }
                                    Divider().frame(height: 28)
                                    profileAction("Видеозвонок", icon: "video") {
                                        TelegramClient.shared.callUser(userId: userId, isVideo: true)
                                        dismiss()
                                    }
                                }
                                .glassPanel(cornerRadius: 14)
                            }

                            if info.typeText == "группа" || info.typeText == "канал" {
                                VStack(spacing: 0) {
                                    profileAction("Участники", icon: "person.2") {
                                        showMembers = true
                                    }
                                    if let myId = TelegramClient.shared.me?.id {
                                        Divider()
                                        profileAction(
                                            myTag.isEmpty ? "Задать мой тег" : "Мой тег: \(myTag)",
                                            icon: "tag"
                                        ) {
                                            showMyTag = true
                                        }
                                        .task(id: myId) {
                                            myTag = await TelegramClient.shared.memberTag(chatId: chatId, userId: myId) ?? ""
                                        }
                                    }
                                    if info.directMessagesChatId != nil {
                                        Divider()
                                        profileAction("Сообщения каналу", icon: "paperplane") {
                                            showDirectMessages = true
                                        }
                                    }
                                    if info.linkedChatId != nil {
                                        Divider()
                                        profileAction(L10n.keyed("Chat.Discussion", ru: "Обсуждение", en: "Go to discussion"),
                                                      icon: "bubble.left.and.bubble.right") {
                                            showLinkedChat = true
                                        }
                                    }
                                }
                                .glassPanel(cornerRadius: 14)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(L10n.t("Auto.38ca0af80c"))
                                    .font(.appHeadline)
                                if info.description.isEmpty {
                                    Text(L10n.t("Auto.9afa89a8ea"))
                                        .font(.appBody)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(LinkifiedText.attributed(info.description))
                                        .font(.appBody)
                                        .tint(.accentColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(.secondarySystemBackground))
                            )

                            VStack(alignment: .leading, spacing: 10) {
                                Text(L10n.t("Auto.33b7f0848a"))
                                    .font(.appHeadline)
                                Text(L10n.t("Auto.1d0747f186"))
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                                TextField(L10n.t("Auto.602680ed89"), text: $localAlias)
                                    .textFieldStyle(.roundedBorder)
                                Button(L10n.t("Auto.373f49e7c6")) {
                                    aliases.setChatAlias(localAlias, chatId: chatId)
                                    if let userId = ChatStore.shared.chats[chatId]?.privateUserId {
                                        aliases.setUserAlias(localAlias, userId: userId)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 24)
                    }
                    .background(GlassBackgroundView(cornerRadius: 0).ignoresSafeArea())
                } else {
                    Text(L10n.t("Auto.1afac88324"))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("Auto.a7fd9bee17"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let info, info.typeText == "канал" || info.typeText == "группа" {
                        Menu {
                            Button { showEditor = true } label: {
                                Label(L10n.t("Auto.47e2436e55"), systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) { showLeaveConfirm = true } label: {
                                Label(
                                    info.typeText == "канал" ? "Покинуть канал" : "Покинуть группу",
                                    systemImage: "rectangle.portrait.and.arrow.right"
                                )
                            }
                        } label: {
                            Text(L10n.t("Auto.47e2436e55"))
                        }
                    }
                }
            }
            .fullScreenCover(item: $avatarViewer) { payload in
                AvatarViewerView(photos: payload.photos, title: payload.title)
            }
            .confirmationDialog(
                "Покинуть \(info?.typeText ?? "чат")?",
                isPresented: $showLeaveConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.t("Auto.d1f6482cf4"), role: .destructive) { leaveChat() }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text("Вы перестанете получать сообщения из этого \(info?.typeText ?? "чата"). Действие нельзя отменить.")
            }
            .alert(L10n.t("Auto.7ae167ed6e"), isPresented: $showAvatarError) {
                Button("OK", role: .cancel) {}
            }
            .sheet(isPresented: $showGifts) {
                GiftsView(
                    owner: giftOwner,
                    title: info?.title ?? "Подарки"
                )
            }
            .sheet(isPresented: $showMembers) {
                ChatMembersView(chatId: chatId, title: info?.title ?? "Участники")
            }
            .sheet(isPresented: $showMyTag) {
                if let myId = TelegramClient.shared.me?.id {
                    MemberTagView(chatId: chatId, userId: myId)
                        .onDisappear {
                            Task {
                                myTag = await TelegramClient.shared.memberTag(chatId: chatId, userId: myId) ?? ""
                            }
                        }
                }
            }
            .sheet(isPresented: $showDirectMessages) {
                if let direct = info?.directMessagesChatId {
                    NavigationView {
                        ChatView(chatId: direct)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(L10n.t("Common.Close")) { showDirectMessages = false }
                                }
                            }
                    }
                }
            }
            .sheet(isPresented: $showLinkedChat) {
                if let linked = info?.linkedChatId {
                    NavigationView {
                        ChatView(chatId: linked)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(L10n.t("Common.Close")) { showLinkedChat = false }
                                }
                            }
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                if let info {
                    ChannelEditorView(
                        chatId: chatId,
                        initialTitle: info.title,
                        initialDescription: info.description,
                        initialUsername: info.username,
                        initialPhoto: info.photo
                    )
                }
            }
            .task {
                info = await TelegramClient.shared.peerInfo(chatId: chatId)
                localAlias = aliases.chatAlias(chatId) ?? ""
                isLoading = false
            }
            .environment(\.openURL, OpenURLAction { url in
                if handleLink(url) { return .handled }
                return .systemAction
            })
            .background(
                NavigationLink(
                    destination: Group {
                        if let taggedChatId {
                            ChatView(chatId: taggedChatId)
                        }
                    },
                    isActive: Binding(
                        get: { taggedChatId != nil },
                        set: { if !$0 { taggedChatId = nil } }
                    )
                ) { EmptyView() }
                .hidden()
            )
        }
        .navigationViewStyle(.stack)
    }

    private func handleLink(_ url: URL) -> Bool {
        guard let username = Self.username(from: url) else { return false }
        Task {
            if let id = await TelegramClient.shared.resolveUsername(username), id != chatId {
                taggedChatId = id
            }
        }
        return true
    }

    private static func username(from url: URL) -> String? {
        let host = url.host?.lowercased()
        if host == "t.me" || host == "telegram.me" || host == "www.t.me" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard let first = parts.first, !first.isEmpty,
                  !first.hasPrefix("+"), first != "joinchat", first != "s" else { return nil }
            return first
        }
        if url.scheme == "tg", url.host == "resolve" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "domain" })?
                .value
        }
        return nil
    }

    private var giftOwner: MessageSender {
        if let userId = info?.userId {
            return .messageSenderUser(MessageSenderUser(userId: userId))
        }
        return .messageSenderChat(MessageSenderChat(chatId: chatId))
    }

    private func leaveChat() {
        Task {
            do {
                try await TelegramClient.shared.leaveChat(chatId)
                dismiss()
            } catch {
                TelegramClient.shared.errorMessage = TelegramClient.describe(error)
            }
        }
    }

    private func profileAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 24)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.appBody)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AvatarViewerPayload: Identifiable {
    let id = UUID()
    let photos: [AvatarPhoto]
    let title: String
}

private enum LinkifiedText {
    static func attributed(_ text: String) -> AttributedString {
        guard let regex = try? NSRegularExpression(
            pattern: #"(https?://[^\s]+|t\.me/[^\s]+|@[A-Za-z0-9_]{3,})"#
        ) else {
            return AttributedString(text)
        }

        var result = AttributedString()
        var cursor = text.startIndex
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += AttributedString(String(text[cursor..<range.lowerBound]))

            var visible = String(text[range])
            var suffix = ""
            let punctuation = CharacterSet(charactersIn: ".,;:!?)]}")
            while let last = visible.unicodeScalars.last, punctuation.contains(last) {
                suffix = String(last) + suffix
                visible.removeLast()
            }

            let link: URL?
            if visible.hasPrefix("http://") || visible.hasPrefix("https://") {
                link = URL(string: visible)
            } else if visible.hasPrefix("t.me/") {
                link = URL(string: "https://" + visible)
            } else if visible.hasPrefix("@") {
                link = URL(string: "https://t.me/" + visible.dropFirst())
            } else {
                link = nil
            }

            var piece = AttributedString(visible)
            piece.link = link
            result += piece
            result += AttributedString(suffix)
            cursor = range.upperBound
        }

        result += AttributedString(String(text[cursor...]))
        return result
    }

}
