import SwiftUI
import TDLibKit

/// Separate music tab: library, import from Files/Telegram, mini player and full player.
struct MusicView: View {
    @ObservedObject private var library = MusicLibrary.shared
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var client = TelegramClient.shared

    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case main, chats, saved, favorites, profile, recent
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .main: return LocalizedStringKey(L10n.t("AutoT.f96a4e3ca8"))
            case .chats: return LocalizedStringKey(L10n.t("AutoT.19adecc3d1"))
            case .saved: return LocalizedStringKey(L10n.t("AutoT.2fc4139291"))
            case .favorites: return LocalizedStringKey(L10n.t("AutoT.3a8413a42e"))
            case .profile: return LocalizedStringKey(L10n.t("AutoT.a46c372347"))
            case .recent: return LocalizedStringKey(L10n.t("AutoT.83c8b9632d"))
            }
        }
    }

    @State private var showFilePicker = false
    @ObservedObject private var sleepTimer = SleepTimer.shared
    @State private var shareItem: ShareAudioFile?
    @State private var showFullPlayer = false
    @State private var filter: LibraryFilter = .main
    @State private var showChatPicker = false
    @State private var showImportDestination = false
    @State private var pendingImportChatId: Int64?
    @State private var pendingImportTitle = ""
    @State private var showDeleteAllConfirmation = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var isSelecting = false
    @State private var selectedTrackIDs: Set<String> = []
    @State private var showForwardPicker = false
    @State private var profileAudios: [TDLibKit.Audio] = []
    @State private var isLoadingProfile = false
    @State private var isImportingProfile = false
    @State private var showProfileUserPicker = false
    @ObservedObject private var classic = ClassicDesignMode.shared
    @State private var profileMusicTarget: ProfileMusicTarget?
    @State private var editingTrack: MusicTrack?

    private var mainTracks: [MusicTrack] {
        library.tracks.filter { $0.sourceChatId == nil && matchesSearch($0) }
    }

    private var chatTracks: [MusicTrack] {
        library.tracks.filter {
            $0.sourceChatId != nil && $0.sourceTitle != "Из профиля" && matchesSearch($0)
        }
    }

    private var savedTracks: [MusicTrack] {
        library.tracks.filter {
            ($0.sourceTitle == "Из избранного" || $0.sourceTitle == "Из профиля") && matchesSearch($0)
        }
    }

    private var filteredProfileAudios: [TDLibKit.Audio] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profileAudios }
        return profileAudios.filter {
            SearchMatcher.matches("\($0.title) \($0.performer)", query: query)
        }
    }

    private var recentTracks: [MusicTrack] {
        library.tracks
            .filter { $0.lastPlayedAt != nil && matchesSearch($0) }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    private var displayedTracks: [MusicTrack] {
        switch filter {
        case .main: return mainTracks
        case .chats: return chatTracks
        case .saved: return savedTracks
        case .favorites: return library.tracks.filter { ($0.isFavorite ?? false) && matchesSearch($0) }
        case .profile: return []
        case .recent: return recentTracks
        }
    }

    private func matchesSearch(_ track: MusicTrack) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return SearchMatcher.matches("\(track.title) \(track.artist)", query: query)
    }

    private var chatGroups: [(String, [MusicTrack])] {
        Dictionary(grouping: chatTracks, by: { $0.sourceTitle ?? "Из чатов" })
            .map { ($0.key, $0.value.sorted { $0.addedAt > $1.addedAt }) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                musicSearchBar
                if classic.isEnabled {
                    classicMusicHeader
                }
                if player.current != nil {
                    GlobalPlayerBar()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibraryFilter.allCases) { item in
                            Button {
                                filter = item
                                if item == .profile {
                                    Task { await loadProfileAudios() }
                                }
                            } label: {
                                Text(item.title)
                                    .font(.appFootnote)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule().fill(
                                            filter == item
                                                ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                                : AnyShapeStyle(.ultraThinMaterial)
                                        )
                                    )
                                    .foregroundColor(filter == item ? .accentColor : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if filter == .profile {
                    profileContent
                } else if displayedTracks.isEmpty {
                    emptyState
                } else {
                    trackList
                }
            }
            .navigationTitle(L10n.t("Auto.0660a7580a"))
            .navigationBarHidden(classic.isEnabled)

            .task { await loadProfileAudios() }
            .toolbar {
                musicToolbar
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.t("Common.Done")) { dismissKeyboard() }
                }
            }
            .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            .sheet(isPresented: $showFilePicker) {
                DocumentPicker { urls in
                    Task { await library.importFiles(urls) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showFullPlayer) {
                FullMusicPlayerView()
            }
            .sheet(isPresented: $showChatPicker) {
                ChatPickerView(title: L10n.t("AutoT.856e080cfa")) { chatId in
                    pendingImportChatId = chatId
                    pendingImportTitle = ChatStore.shared.chats[chatId]?.title ?? L10n.t("AutoT.c52b4c5cbc")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showImportDestination = true
                    }
                }
            }
            .sheet(isPresented: $showProfileUserPicker) {
                ChatPickerView(title: L10n.t("AutoT.4f8f16b854")) { chatId in
                    if let userId = ChatStore.shared.chats[chatId]?.privateUserId {
                        profileMusicTarget = ProfileMusicTarget(
                            id: userId,
                            title: ChatStore.shared.chats[chatId]?.title ?? "Музыка профиля"
                        )
                    }
                }
            }
            .sheet(item: $profileMusicTarget) { target in
                ProfileMusicView(userId: target.id, title: target.title)
            }
            .sheet(item: $editingTrack) { track in
                TrackMetadataView(track: track)
            }
            .sheet(isPresented: $showForwardPicker) {
                ChatPickerView(title: L10n.t("AutoT.bf1f3f491a")) { chatId in
                    let tracks = library.tracks.filter { selectedTrackIDs.contains($0.id) }
                    Task { await client.sendTracks(tracks, to: chatId) }
                    isSelecting = false
                    selectedTrackIDs.removeAll()
                }
            }
            .confirmationDialog(L10n.t("Auto.471357e4eb"),
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.t("Auto.e343cc909a"), role: .destructive) {
                    player.stop()
                    library.deleteAll()
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t("Auto.2b5d8b4a77"))
            }
            .confirmationDialog(L10n.t("Auto.e0f429ff67"),
                isPresented: $showImportDestination,
                titleVisibility: .visible
            ) {
                Button(L10n.t("Auto.4a887e6a87")) { startImport(toMain: true) }
                Button(L10n.t("Auto.771287d667")) { startImport(toMain: false) }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text(String(format: L10n.t("AutoI.ba1703efad"), String(describing: pendingImportTitle)))
            }
            .overlay { importOverlay }
            .overlay(alignment: .top) { errorOverlay }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var importOverlay: some View {
        if library.isImporting {
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.t("Auto.256aeb5a77")).font(.appFootnote)
                Text(library.importProgress)
                    .font(.appCaption2)
                    .foregroundColor(.secondary)
                Button(L10n.t("Auto.a4edb94a09")) {
                    library.cancelImport()
                }
                .buttonStyle(.bordered)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8)
        }
    }

    @ViewBuilder
    private var errorOverlay: some View {
        if let error = library.errorText, !library.isImporting {
            Text(error)
                .font(.appFootnote)
                .foregroundColor(.red)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
                .onAppear {
                    Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if library.errorText == error {
                            library.errorText = nil
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var musicSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(L10n.t("Auto.1f76be6ddc"), text: $search)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
            if searchFocused || !search.isEmpty {
                Button(L10n.t("Common.Cancel")) {
                    search = ""
                    searchFocused = false
                    dismissKeyboard()
                }
                .font(.appFootnote)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .glassPanel(cornerRadius: 14)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var classicMusicHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Button { mix() } label: {
                    Image(systemName: "shuffle").font(.system(size: 21))
                }
                .buttonStyle(.plain)
                .disabled(library.tracks.isEmpty)

                Button {
                    isSelecting.toggle()
                    if !isSelecting { selectedTrackIDs.removeAll() }
                } label: {
                    Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 21))
                }
                .buttonStyle(.plain)
                .disabled(library.tracks.isEmpty)

                Spacer()

                if player.current != nil {
                    Button { player.stop() } label: {
                        Image(systemName: "stop.fill").font(.system(size: 19))
                    }
                    .buttonStyle(.plain)
                    Button { showFullPlayer = true } label: {
                        Image(systemName: "play.circle").font(.system(size: 21))
                    }
                    .buttonStyle(.plain)
                }

                Button { showChatPicker = true } label: {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 21))
                }
                .buttonStyle(.plain)

                Button { showFilePicker = true } label: {
                    Image(systemName: "plus").font(.system(size: 22))
                }
                .buttonStyle(.plain)

                Menu {
                    Button { Task { await library.importSavedMessagesMusic() } } label: {
                        Label(L10n.t("Auto.cfc70daf8e"), systemImage: "bookmark")
                    }
                    Button { showProfileUserPicker = true } label: {
                        Label(L10n.t("Auto.77dc4920b5"), systemImage: "person.crop.circle.badge.music.note")
                    }
                    Button(role: .destructive) { showDeleteAllConfirmation = true } label: {
                        Label(L10n.t("Auto.e343cc909a"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 22))
                }
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 16)
            .padding(.top, 10)

            Text(L10n.t("Auto.0660a7580a"))
                .font(FontManager.shared.font(size: 38, weight: .heavy))
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
        }
    }

    @ToolbarContentBuilder
    private var musicToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Button {
                mix()
            } label: {
                Image(systemName: "shuffle")
            }
            .disabled(library.tracks.isEmpty)
            .accessibilityLabel(L10n.t("Auto.f00f35b61d"))

            Button {
                isSelecting.toggle()
                if !isSelecting { selectedTrackIDs.removeAll() }
            } label: {
                Image(systemName: isSelecting ? "xmark.circle" : "checkmark.circle")
            }
            .disabled(library.tracks.isEmpty)
            .accessibilityLabel(isSelecting ? "Отменить выбор" : "Выбрать треки")
        }

        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if isSelecting {
                Button {
                    showForwardPicker = true
                } label: {
                    Label(String(format: L10n.t("Music.SendCount"), selectedTrackIDs.count), systemImage: "paperplane")
                }
                .disabled(selectedTrackIDs.isEmpty)
            } else {

                if player.current != nil {
                    Button {
                        player.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .accessibilityLabel(L10n.t("Auto.b1c7a97dfd"))

                    Button {
                        showFullPlayer = true
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .accessibilityLabel(L10n.t("Auto.bd9bf3261d"))
                }
                Button {
                    showChatPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel(L10n.t("Auto.e809b32a1f"))
                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.t("Auto.95cd4ea4d0"))

                if !library.tracks.isEmpty {
                    Menu {
                        if let current = player.current {
                            Button {
                                shareItem = ShareAudioFile(url: library.url(for: current))
                            } label: {
                                Label(L10n.t("Auto.0d8a4d5356"), systemImage: "square.and.arrow.up")
                            }
                        }
                        Menu {
                            Button(L10n.t("Cache.AutoCleanOff")) { SleepTimer.shared.set(minutes: 0) }
                            Button(L10n.t("Auto.a53e0a5f1b")) { SleepTimer.shared.set(minutes: 15) }
                            Button(L10n.t("Auto.d2152c9c19")) { SleepTimer.shared.set(minutes: 30) }
                            Button(L10n.t("Auto.5a838e04cc")) { SleepTimer.shared.set(minutes: 60) }
                        } label: {
                            Label(SleepTimer.shared.isActive
                                  ? "Таймер сна (\\(SleepTimer.shared.remainingText))"
                                  : "Таймер сна",
                                  systemImage: "moon.zzz")
                        }
                        Button {
                            Task { await library.importSavedMessagesMusic() }
                        } label: {
                            Label(L10n.t("Auto.cfc70daf8e"), systemImage: "bookmark")
                        }
                        Button {
                            showProfileUserPicker = true
                        } label: {
                            Label(L10n.t("Auto.77dc4920b5"), systemImage: "person.crop.circle.badge.music.note")
                        }
                        Button(role: .destructive) {
                            showDeleteAllConfirmation = true
                        } label: {
                            Label(L10n.t("Auto.e343cc909a"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(L10n.t("Auto.4533ba2a34"))
                }
            }
        }
    }

    private func startImport(toMain: Bool) {
        guard let chatId = pendingImportChatId else { return }
        let title = pendingImportTitle
        filter = toMain ? .main : .chats
        Task {
            await library.importChat(chatId: chatId, title: title, toMain: toMain)
        }
    }

    private func delete(_ track: MusicTrack) {
        library.delete(track)
        if player.current?.id == track.id {
            player.stop()
        }
    }

    /// Starts a shuffled mix: random first track and random next tracks.
    private func mix() {
        player.shuffle = true
        let source = displayedTracks
        if let track = source.randomElement() {
            player.play(track, queue: source)
        }
    }

    @ViewBuilder
    private var profileContent: some View {
        if isLoadingProfile {
            Spacer()
            ProgressView("Загрузка музыки профиля…")
            Spacer()
        } else if filteredProfileAudios.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 54))
                    .foregroundColor(.secondary)
                Text(L10n.t("Auto.dea6e845aa"))
                    .font(.title3.bold())
                Text(L10n.t("Auto.536a5c04ec"))
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button(L10n.t("Auto.dbe5444a9a")) {
                    Task { await loadProfileAudios() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    Button {
                        isImportingProfile = true
                        Task {
                            await library.importProfileAudios(profileAudios)
                            isImportingProfile = false
                        }
                    } label: {
                        Label(L10n.t("Auto.510c09a51f"), systemImage: "plus.circle")
                    }
                    .disabled(isImportingProfile)
                } footer: {
                    Text(L10n.t("Auto.a984a231e4"))
                        .font(.appFootnote)
                }

                Section(header: Text(L10n.t("Auto.cb2fdd59ac"))) {
                    ForEach(filteredProfileAudios, id: \.audio.id) { audio in
                        HStack(spacing: 10) {
                            ProfileAudioArtwork(audio: audio, size: 42)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(audio.title.isEmpty ? audio.fileName : audio.title)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                Text(audio.performer.isEmpty ? "Неизвестный исполнитель" : audio.performer)
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                Task {
                                    if let track = await library.ensureImported(audio: audio) {
                                        player.play(track, queue: library.tracks)
                                    }
                                }
                            } label: {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 22))
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task { await library.importProfileAudios([audio]) }
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 22))
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await client.removeFromProfileAudio(audio)
                                    await loadProfileAudios()
                                }
                            } label: {
                                Label(L10n.t("Auto.6ff3222195"), systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button {
                                Task {
                                    await client.moveProfileAudioToTop(audio)
                                    await loadProfileAudios()
                                }
                            } label: {
                                Label(L10n.t("Auto.d6d1c415dd"), systemImage: "arrow.up.to.line")
                            }
                            Button(role: .destructive) {
                                Task {
                                    await client.removeFromProfileAudio(audio)
                                    await loadProfileAudios()
                                }
                            } label: {
                                Label(L10n.t("Auto.6ff3222195"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func loadProfileAudios() async {
        guard !isLoadingProfile else { return }
        isLoadingProfile = true
        profileAudios = await client.profileAudios()
        isLoadingProfile = false
    }

    private var trackList: some View {
        List {
            if filter == .chats {
                ForEach(chatGroups, id: \.0) { group in
                    Section(header: Text(group.0)) {
                        ForEach(group.1) { track in
                            trackRow(track, queue: group.1)
                        }
                    }
                }
            } else if filter == .recent {
                ForEach(recentTracks) { track in
                    trackRow(track, queue: recentTracks)
                }
            } else if filter == .saved {
                ForEach(savedTracks) { track in
                    trackRow(track, queue: savedTracks)
                }
            } else if filter == .favorites {
                ForEach(library.tracks.filter { $0.isFavorite ?? false }) { track in
                    trackRow(track, queue: library.tracks.filter { $0.isFavorite ?? false })
                }
            } else {
                ForEach(mainTracks) { track in
                    trackRow(track, queue: mainTracks)
                }
            }
        }
        .listStyle(.plain)
    }

    private func trackRow(_ track: MusicTrack, queue: [MusicTrack]) -> some View {
        Button {
            if isSelecting {
                if selectedTrackIDs.contains(track.id) {
                    selectedTrackIDs.remove(track.id)
                } else {
                    selectedTrackIDs.insert(track.id)
                }
            } else {
                player.play(track, queue: queue)
            }
        } label: {
            HStack(spacing: 12) {
                MusicArtworkView(track: track, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(track.artist.isEmpty ? "Неизвестный исполнитель" : track.artist)
                            .lineLimit(1)
                        if let duration = track.duration, duration > 0 {
                            Text("• \(duration / 60):\(String(format: "%02d", duration % 60))")
                        }
                    }
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                if isSelecting {
                    Image(systemName: selectedTrackIDs.contains(track.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(selectedTrackIDs.contains(track.id) ? .accentColor : .secondary)
                } else if player.current?.id == track.id {
                    Image(systemName: player.isPlaying ? "waveform" : "play.fill")
                        .foregroundColor(.accentColor)
                } else if track.isFavorite == true {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(track)
            } label: {
                Label(L10n.t("Common.Delete"), systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                library.toggleFavorite(track)
            } label: {
                Label(track.isFavorite == true ? "Убрать из любимых" : "В любимые", systemImage: track.isFavorite == true ? "heart.slash" : "heart")
            }
            Button {
                editingTrack = track
            } label: {
                Label(L10n.t("Auto.8d562f2d73"), systemImage: "pencil")
            }
            Button {
                selectedTrackIDs = [track.id]
                isSelecting = true
                showForwardPicker = true
            } label: {
                Label(L10n.t("Common.Send"), systemImage: "paperplane")
            }
            Button {
                Task {
                    await client.addToProfileAudio(track)
                    await loadProfileAudios()
                }
            } label: {
                Label(L10n.t("Auto.6256120324"), systemImage: "person.crop.circle.badge.plus")
            }
            Button(role: .destructive) {
                delete(track)
            } label: {
                Label(L10n.t("Auto.570f024547"), systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: emptyIcon)
                .font(.system(size: 54))
                .foregroundColor(.secondary)
            Text(emptyTitle)
                .font(.title3.bold())
            Text(emptySubtitle)
                .font(.appFootnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(emptyActionTitle) {
                switch filter {
                case .main:
                    showFilePicker = true
                case .saved:
                    Task { await library.importSavedMessagesMusic() }
                case .profile:
                    Task { await loadProfileAudios() }
                case .favorites:
                    filter = .main
                case .chats, .recent:
                    showChatPicker = true
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyIcon: String {
        switch filter {
        case .main: return "music.note.list"
        case .chats: return "square.stack.3d.down.right"
        case .saved: return "bookmark"
        case .favorites: return "heart.fill"
        case .profile: return "person.crop.circle"
        case .recent: return "clock.arrow.circlepath"
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch filter {
        case .main: return LocalizedStringKey(L10n.t("AutoT.9e46a9b5fb"))
        case .chats: return LocalizedStringKey(L10n.t("AutoT.a45f76d1b3"))
        case .saved: return LocalizedStringKey(L10n.t("AutoT.ebff628e93"))
        case .favorites: return LocalizedStringKey(L10n.t("AutoT.51733596d1"))
        case .profile: return LocalizedStringKey(L10n.t("AutoT.dea6e845aa"))
        case .recent: return LocalizedStringKey(L10n.t("AutoT.87ae3be1c3"))
        }
    }

    private var emptySubtitle: LocalizedStringKey {
        switch filter {
        case .main: return LocalizedStringKey(L10n.t("AutoT.11be415c9e"))
        case .chats: return LocalizedStringKey(L10n.t("AutoT.fd0cd6fc65"))
        case .saved: return LocalizedStringKey(L10n.t("AutoT.7c351f8262"))
        case .favorites: return LocalizedStringKey(L10n.t("AutoT.51f4d5f407"))
        case .profile: return LocalizedStringKey(L10n.t("AutoT.05ace2ea77"))
        case .recent: return LocalizedStringKey(L10n.t("AutoT.45393afa4f"))
        }
    }

    private var emptyActionTitle: LocalizedStringKey {
        switch filter {
        case .main: return LocalizedStringKey(L10n.t("AutoT.56d82d4ad1"))
        case .saved: return LocalizedStringKey(L10n.t("AutoT.cfc70daf8e"))
        case .favorites: return LocalizedStringKey(L10n.t("AutoT.2f932a199a"))
        case .profile: return LocalizedStringKey(L10n.t("AutoT.dbe5444a9a"))
        case .chats, .recent: return LocalizedStringKey(L10n.t("AutoT.b73e6cf682"))
        }
    }
}

struct ProfileMusicTarget: Identifiable {
    let id: Int64
    let title: String
}

/// Artwork for an audio file that lives only in the Telegram profile.
struct ProfileAudioArtwork: View {
    let audio: TDLibKit.Audio
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.purple.opacity(0.8), .pink.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: audio.albumCoverThumbnail?.file.id ?? audio.audio.id) {
            guard let file = audio.albumCoverThumbnail?.file ?? audio.externalAlbumCovers.first?.file,
                  let url = await TelegramClient.shared.localFileURL(file) else {
                image = nil
                return
            }
            image = await ImageCache.imageAsync(atPath: url.path, maxPixel: size * 2)
        }
    }
}

/// Square track artwork with the previous gradient placeholder when no cover exists.
struct MusicArtworkView: View {
    let track: MusicTrack?
    let size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.purple.opacity(0.8), .pink.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .task(id: track?.artworkFileName) {
            guard let track, let url = MusicLibrary.shared.artworkURL(for: track) else {
                image = nil
                return
            }
            image = await ImageCache.imageAsync(atPath: url.path, maxPixel: size * 2)
        }
    }
}

/// Compact player available on every tab and inside chats.
struct GlobalPlayerBar: View {
    @ObservedObject private var player = MusicPlayer.shared
    @State private var showFullPlayer = false

    var body: some View {
        HStack(spacing: 10) {
            Button { showFullPlayer = true } label: {
                HStack(spacing: 10) {
                    MusicArtworkView(track: player.current, size: 34)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.current?.title ?? "")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(player.current?.artist ?? "")
                            .font(.appCaption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")

            Button {
                player.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("Auto.b1c7a97dfd"))
        }
        .id(player.current?.id)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
        .animation(.easeOut(duration: 0.22), value: player.current?.id)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassPanel(cornerRadius: 18)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .sheet(isPresented: $showFullPlayer) {
            FullMusicPlayerView()
        }
    }
}

/// Full-screen player with scrubber, shuffle and repeat.
struct FullMusicPlayerView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var classic = ClassicDesignMode.shared
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var sleepTask: Task<Void, Never>?
    @State private var sleepUntil: Foundation.Date?
    @State private var coverRotation: Double = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Spacer(minLength: 10)

                // The rotating container must persist across track changes:
                // .id() is applied to the artwork inside, otherwise the
                // rotation view is recreated and onChange never fires.
                ZStack {
                    MusicArtworkView(track: player.current, size: 300)
                        .frame(maxWidth: 300, maxHeight: 300)
                        .aspectRatio(1, contentMode: .fit)
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                        .id(player.current?.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.92).combined(with: .opacity),
                            removal: .scale(scale: 1.04).combined(with: .opacity)
                        ))
                }
                .rotationEffect(.degrees(coverRotation))
                .animation(.spring(response: 0.55, dampingFraction: 0.78), value: coverRotation)
                .onChange(of: player.current?.id) { _ in
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                        coverRotation += 360
                    }
                }

                VStack(spacing: 4) {
                    Text(player.current?.title ?? "Ничего не играет")
                        .font(.title2.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(player.current?.artist ?? "")
                        .font(.appSubheadline)
                        .foregroundColor(.secondary)
                }
                .id(player.current?.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.22), value: player.current?.id)
                .padding(.horizontal)

                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { scrub ?? player.progress },
                            set: { value in
                                scrub = value
                                player.previewSeek(to: value)
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if editing {
                                player.beginScrubbing()
                            } else {
                                player.seek(to: scrub ?? player.progress)
                                player.endScrubbing()
                                scrub = nil
                            }
                        }
                    )
                    .disabled(player.duration <= 0)
                    HStack {
                        Text(time( (scrub ?? player.progress) * player.duration))
                        Spacer()
                        Text(time(player.duration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .glassPanel(cornerRadius: 22)

                HStack(spacing: 20) {
                    Button {
                        player.shuffle.toggle()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 20))
                            Text(L10n.t("Auto.f00f35b61d"))
                                .font(.appCaption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(width: 48)
                        }
                        .foregroundColor(player.shuffle ? .accentColor : .secondary)
                    }
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 26))
                    }
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 68))
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 26))
                    }
                    Menu {
                        Button {
                            player.repeatMode = .off
                        } label: {
                            Label(L10n.t("Auto.554a88dabd"), systemImage: player.repeatMode == .off ? "checkmark" : "circle")
                        }
                        Button {
                            player.repeatMode = .all
                        } label: {
                            Label(L10n.t("Auto.5cab2bd1c8"), systemImage: player.repeatMode == .all ? "checkmark" : "circle")
                        }
                        Button {
                            player.repeatMode = .one
                        } label: {
                            Label(L10n.t("Auto.41fede13dc"), systemImage: player.repeatMode == .one ? "checkmark" : "circle")
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: player.repeatMode.icon)
                                .font(.system(size: 20))
                            Text(L10n.t("Auto.dc09f296c9"))
                                .font(.appCaption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .frame(width: 48)
                        }
                        .foregroundColor(player.repeatMode == .off ? .secondary : .accentColor)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 12)
                .padding(.horizontal, 6)
                .glassPanel(cornerRadius: 28)

                HStack(spacing: 24) {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button {
                                player.playbackRate = rate
                            } label: {
                                Label(String(format: "%.2g×", rate), systemImage: abs(player.playbackRate - rate) < 0.01 ? "checkmark" : "circle")
                            }
                        }
                    } label: {
                        Label(String(format: "%.2g×", player.playbackRate), systemImage: "speedometer")
                            .font(.appFootnote)
                    }

                    Menu {
                        Button(L10n.t("Auto.6474339fab")) { cancelSleepTimer() }
                        Button(L10n.t("Auto.a53e0a5f1b")) { setSleepTimer(minutes: 15) }
                        Button(L10n.t("Auto.d2152c9c19")) { setSleepTimer(minutes: 30) }
                        Button(L10n.t("Auto.5a838e04cc")) { setSleepTimer(minutes: 60) }
                    } label: {
                        Label(sleepLabel, systemImage: "moon.zzz")
                            .font(.appFootnote)
                    }
                }
                .padding(.top, 2)

                Spacer(minLength: 20)
            }
            .padding()
            .navigationTitle(L10n.t("Auto.0432bb2a6b"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let track = player.current {
                        Button {
                            MusicLibrary.shared.toggleFavorite(track)
                        } label: {
                            Image(systemName: track.isFavorite == true ? "heart.fill" : "heart")
                                .foregroundColor(track.isFavorite == true ? .red : .primary)
                        }
                        .accessibilityLabel(L10n.t("Auto.ca3c267ce1"))
                        Button(role: .destructive) {
                            MusicLibrary.shared.delete(track)
                            player.stop()
                            dismiss()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(L10n.t("Auto.1c3a480cf1"))
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var sleepLabel: String {
        guard let sleepUntil else { return L10n.t("AutoT.33969aa545") }
        let minutes = max(0, Int(sleepUntil.timeIntervalSinceNow / 60))
        return L10n.t("AutoT.b0af9f38d2")
    }

    private func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        let until = Foundation.Date().addingTimeInterval(Double(minutes) * 60)
        sleepUntil = until
        sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                player.pauseIfPlaying()
                sleepUntil = nil
            }
        }
    }

    private func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepUntil = nil
    }

    private func nextRepeat(_ mode: MusicRepeatMode) -> MusicRepeatMode {
        switch mode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}


struct ShareAudioFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
