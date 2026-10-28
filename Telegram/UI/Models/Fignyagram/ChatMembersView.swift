import SwiftUI
import TDLibKit

struct ChatMembersView: View {
    let chatId: Int64
    let title: String

    private enum Filter: String, CaseIterable, Identifiable {
        case all, admins, members
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Все"
            case .admins: return "Админы"
            case .members: return "Участники"
            }
        }
    }

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var members: [TelegramClient.ChatMemberItem] = []
    @State private var isLoading = false
    @State private var showAdd = false
    @State private var tagMember: TelegramClient.ChatMemberItem?
    @State private var rightsMember: TelegramClient.ChatMemberItem?
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if isLoading && members.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(members) { member in
                            HStack(spacing: 10) {
                                AvatarView(id: member.id, title: member.name, photo: nil, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Text(member.name)
                                            .font(.subheadline.bold())
                                            .lineLimit(1)
                                        if member.isCreator {
                                            Text(L10n.t("Auto.2dd8047b9f"))
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.green.opacity(0.18)))
                                                .foregroundColor(.green)
                                        } else if member.isAdmin {
                                            Text(L10n.t("Auto.e61dfbc3c9"))
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.green.opacity(0.18)))
                                                .foregroundColor(.green)
                                        }
                                        if !member.tag.isEmpty {
                                            Text(member.tag)
                                                .font(.appCaption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    if let username = member.username {
                                        Text("@\(username)")
                                            .font(.appCaption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Menu {
                                    Button {
                                        tagMember = member
                                    } label: {
                                        Label(L10n.t("Auto.958ac8dd2a"), systemImage: "tag")
                                    }
                                    Button {
                                        rightsMember = member
                                    } label: {
                                        Label(member.isAdmin ? "Изменить права" : "Повысить", systemImage: "crown")
                                    }
                                    Button(role: .destructive) {
                                        ban(member, banned: !member.isBanned)
                                    } label: {
                                        Label(member.isBanned ? "Разбанить" : "Забанить", systemImage: "hand.raised")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.appTitle3)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $query, prompt: "Поиск участников")
                    .onChange(of: query) { _ in Task { await load() } }
                }
            }
            .navigationTitle(L10n.t("Auto.85b226b500"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddChatMemberView(chatId: chatId) {
                    Task { await load() }
                }
            }
            .sheet(item: $tagMember) { member in
                MemberTagView(chatId: chatId, userId: member.id)
            }
            .sheet(item: $rightsMember) { member in
                MemberRightsView(chatId: chatId, member: member)
            }
            .overlay(alignment: .top) {
                if let errorText {
                    Text(errorText)
                        .font(.appCaption)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .task(id: filter) { await load() }
        }
        .navigationViewStyle(.stack)
    }

    private func load() async {
        isLoading = true
        members = await client.chatMembers(
            chatId: chatId,
            adminsOnly: filter == .admins,
            query: query
        )
        if filter == .members {
            members = members.filter { !$0.isAdmin }
        }
        isLoading = false
    }

    private func ban(_ member: TelegramClient.ChatMemberItem, banned: Bool) {
        Task {
            do {
                try await client.banChatMember(chatId: chatId, userId: member.id, banned: banned)
                await load()
            } catch {
                errorText = TelegramClient.describe(error)
            }
        }
    }
}

private struct AddChatMemberView: View {
    let chatId: Int64
    let onAdded: () -> Void

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var users: [User] = []
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            List(users, id: \.id) { user in
                Button {
                    Task {
                        do {
                            try await client.addChatMember(chatId: chatId, userId: user.id)
                            onAdded()
                            dismiss()
                        } catch {
                            errorText = TelegramClient.describe(error)
                        }
                    }
                } label: {
                    HStack {
                        AvatarView(
                            id: user.id,
                            title: [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "),
                            photo: nil,
                            size: 38
                        )
                        Text([user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " "))
                        Spacer()
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .navigationTitle(L10n.t("Auto.393f688cda"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Имя или @username")
            .onChange(of: query) { value in
                Task {
                    users = (try? await client.searchContacts(value)) ?? []
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let errorText {
                    Text(errorText).font(.appCaption).padding(8)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct MemberRightsView: View {
    let chatId: Int64
    let member: TelegramClient.ChatMemberItem

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var canChangeInfo = false
    @State private var canDeleteMessages = true
    @State private var canInviteUsers = true
    @State private var canPinMessages = true
    @State private var canManageTags = true
    @State private var canRestrictMembers = true
    @State private var canPromoteMembers = false
    @State private var canManageVideoChats = true
    @State private var isAnonymous = false
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Auto.ef6810058a")) {
                    Toggle(L10n.t("Auto.dfae6632a3"), isOn: $canChangeInfo)
                    Toggle(L10n.t("Auto.feed53a8d8"), isOn: $canDeleteMessages)
                    Toggle(L10n.t("Auto.b8621e1357"), isOn: $canInviteUsers)
                    Toggle(L10n.t("Auto.0c2e4aadaf"), isOn: $canPinMessages)
                    Toggle(L10n.t("Auto.4827b13f99"), isOn: $canManageTags)
                    Toggle(L10n.t("Auto.5638cbc3c3"), isOn: $canRestrictMembers)
                    Toggle(L10n.t("Auto.602a0eb978"), isOn: $canPromoteMembers)
                    Toggle(L10n.t("Auto.d3b3c39034"), isOn: $canManageVideoChats)
                    Toggle(L10n.t("Auto.45b7e78fc4"), isOn: $isAnonymous)
                }
                if member.isAdmin {
                    Section {
                        Button(L10n.t("Auto.2c64c95dee"), role: .destructive) {
                            Task {
                                do {
                                    try await client.demoteChatMember(chatId: chatId, userId: member.id)
                                    dismiss()
                                } catch {
                                    errorText = TelegramClient.describe(error)
                                }
                            }
                        }
                    }
                }
                if let errorText {
                    Text(errorText).foregroundColor(.red).font(.appFootnote)
                }
            }
            .navigationTitle(member.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Save")) { save() }
                        .disabled(isSaving)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        isSaving = true
        let rights = ChatAdministratorRights(
            canChangeInfo: canChangeInfo,
            canDeleteMessages: canDeleteMessages,
            canDeleteStories: false,
            canEditMessages: false,
            canEditStories: false,
            canInviteUsers: canInviteUsers,
            canManageChat: true,
            canManageDirectMessages: false,
            canManageTags: canManageTags,
            canManageTopics: false,
            canManageVideoChats: canManageVideoChats,
            canPinMessages: canPinMessages,
            canPostMessages: false,
            canPostStories: false,
            canPromoteMembers: canPromoteMembers,
            canRestrictMembers: canRestrictMembers,
            canSendWelcomeMessages: false,
            isAnonymous: isAnonymous
        )
        Task {
            do {
                try await client.promoteChatMember(chatId: chatId, userId: member.id, rights: rights)
                dismiss()
            } catch {
                errorText = TelegramClient.describe(error)
                isSaving = false
            }
        }
    }
}
