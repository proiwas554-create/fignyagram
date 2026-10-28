import Foundation
import Combine
import TDLibKit
import TgVoipWebrtc

/// Group (video chat) calls: TDLib provides the call object and the encrypted
/// media segments, the tgcalls engine mixes the participants.
@MainActor
final class GroupCallManager: ObservableObject {
    static let shared = GroupCallManager()

    struct Participant: Identifiable, Equatable {
        let id: Int64
        let name: String
        let isMuted: Bool
        let isSpeaking: Bool
    }

    @Published private(set) var isActive = false
    @Published private(set) var groupCallId: Int = 0
    @Published private(set) var chatId: Int64 = 0
    @Published private(set) var title = ""
    @Published private(set) var stateText = ""
    @Published private(set) var isMuted = false
    @Published private(set) var participants: [Participant] = []
    @Published private(set) var speakerTitles: [String] = []
    @Published var localView: UIView?
    @Published var remoteView: UIView?
    @Published private(set) var isVideoEnabled = false

    private var audioSourceId: Int = 0
    private var ssrcToPeer: [UInt32: Int64] = [:]
    private var peerNames: [Int64: String] = [:]
    private var endpointIds: [Int64: String] = [:]
    private var connected = false

    private static var activityCheckAvailable: Bool { true }

    func handleGroupCallUpdate(_ call: GroupCall) {
        guard isActive, call.id == groupCallId else { return }
        if !call.isActive && isActive {
            leave()
        }
    }

    func handleParticipantIds(_ ids: [Int64]) {
        guard isActive else { return }
        var list: [Participant] = []
        for raw in ids {
            let peerId = raw
            let name = peerNames[peerId] ?? ChatStore.shared.users[peerId].map { [$0.firstName, $0.lastName].filter { !$0.isEmpty }.joined(separator: " ") } ?? "Участник"
            peerNames[peerId] = name
            let existing = participants.first(where: { $0.id == peerId })
            list.append(Participant(id: peerId, name: name,
                                    isMuted: existing?.isMuted ?? false,
                                    isSpeaking: existing?.isSpeaking ?? false))
        }
        participants = list
        speakerTitles = participants.filter(\.isSpeaking).map(\.name)
    }

    func handleParticipant(_ participant: GroupCallParticipant) {
        guard isActive else { return }
        let peerId = Self.peerId(participant.participantId)
        if participant.audioSourceId > 0 {
            ssrcToPeer[UInt32(participant.audioSourceId)] = peerId
        }
        if let endpoint = participant.videoInfo?.endpointId, !endpoint.isEmpty {
            endpointIds[peerId] = endpoint
            if isVideoEnabled {
                VoIPBridge.shared().addGroupRemoteVideo(forEndpoint: endpoint)
            }
        }
        let name = peerNames[peerId] ?? ChatStore.shared.users[peerId].map { [$0.firstName, $0.lastName].filter { !$0.isEmpty }.joined(separator: " ") } ?? "Участник"
        peerNames[peerId] = name
        let entry = Participant(id: peerId, name: name,
                                isMuted: participant.isMutedForCurrentUser || participant.isMutedForAllUsers,
                                isSpeaking: participant.isSpeaking)
        if let index = participants.firstIndex(where: { $0.id == peerId }) {
            participants[index] = entry
        } else {
            participants.append(entry)
        }
        speakerTitles = participants.filter(\.isSpeaking).map(\.name)
    }

    func handleParticipants(_ updated: [GroupCallParticipant]) {
        guard isActive else { return }
        var list: [Participant] = []
        ssrcToPeer.removeAll()
        for participant in updated {
            let peerId = Self.peerId(participant.participantId)
            let name = peerNames[peerId] ?? ChatStore.shared.users[peerId].map { [$0.firstName, $0.lastName].filter { !$0.isEmpty }.joined(separator: " ") } ?? "Участник"
            peerNames[peerId] = name
            if participant.audioSourceId > 0 {
                ssrcToPeer[UInt32(participant.audioSourceId)] = peerId
            }
            list.append(Participant(id: peerId, name: name,
                                    isMuted: participant.isMutedForCurrentUser || participant.isMutedForAllUsers,
                                    isSpeaking: participant.isSpeaking))
        }
        self.participants = list.sorted { $0.name < $1.name }
        speakerTitles = list.filter(\.isSpeaking).map(\.name)
    }

    private static func peerId(_ sender: MessageSender) -> Int64 {
        switch sender {
        case .messageSenderUser(let user): return user.userId
        case .messageSenderChat(let chat): return chat.chatId
        }
    }

    func start(chatId: Int64, title: String, video: Bool = false) async {
        guard let client = TelegramClient.shared.tdClient else { return }
        do {
            let created = try await client.createVideoChat(chatId: chatId, isRtmpStream: false, startDate: 0, title: title)
            CallDiag.log("group call created id=\(created.id)")
            await join(groupCallId: created.id, chatId: chatId, title: title, video: video)
        } catch {
            CallDiag.log("group call create failed \(error)")
            TelegramClient.shared.errorMessage = "Не удалось создать групповой звонок: \(TelegramClient.describe(error))"
        }
    }

    /// Starts a new group call or joins the one already running in the chat.
    func startOrJoin(chatId: Int64, title: String, video: Bool = false) async {
        guard let client = TelegramClient.shared.tdClient else { return }
        if let chat = try? await client.getChat(chatId: chatId), chat.videoChat.groupCallId != 0 {
            CallDiag.log("group call exists id=\(chat.videoChat.groupCallId), joining")
            await join(groupCallId: chat.videoChat.groupCallId, chatId: chatId, title: title, video: video)
        } else {
            await start(chatId: chatId, title: title, video: video)
        }
    }

    func join(groupCallId: Int, chatId: Int64, title: String, video: Bool = false) async {
        guard let client = TelegramClient.shared.tdClient else { return }
        self.groupCallId = groupCallId
        self.chatId = chatId
        self.title = title
        isActive = true
        isMuted = false
        stateText = L10n.t("AutoR.2d3f73a394")
        connected = false
        CallDiag.log("group join id=\(groupCallId)")

        let bridge = VoIPBridge.shared()
        bridge.groupStateHandler = { [weak self] connected in
            guard let self else { return }
            self.connected = connected
            self.stateText = connected ? "В групповом звонке" : "Переподключение…"
            CallDiag.log("group engine connected=\(connected)")
        }
        bridge.groupAudioLevelsHandler = { [weak self] levels in
            guard let self else { return }
            self.updateLevels(levels)
        }
        bridge.groupCurrentTimeRequest = { completion in
            completion(Int64(Date().timeIntervalSince1970 * 1000))
        }
        bridge.groupMediaChannelsRequest = { [weak self] ssrcs, completion in
            guard let self else { completion([]); return }
            var descriptions: [OngoingGroupCallMediaChannelDescription] = []
            for number in ssrcs {
                let ssrc = number.uint32Value
                let peer = self.ssrcToPeer[ssrc] ?? 0
                descriptions.append(OngoingGroupCallMediaChannelDescription(
                    type: .audio, peerId: peer, audioSsrc: ssrc, videoDescription: nil))
            }
            completion(descriptions)
        }
        bridge.groupAudioPartRequest = { [weak self] timestamp, duration, completion in
            guard let self else {
                completion(OngoingGroupCallBroadcastPart(timestampMilliseconds: timestamp, responseTimestamp: 0, status: .notReady, oggData: Data()))
                return
            }
            Task { @MainActor in
                let part = await self.fetchAudioPart(timestamp: timestamp, duration: duration)
                completion(part ?? OngoingGroupCallBroadcastPart(timestampMilliseconds: timestamp,
                                                                 responseTimestamp: Date().timeIntervalSince1970,
                                                                 status: .notReady,
                                                                 oggData: Data()))
            }
        }
        bridge.groupEncryptDecrypt = { data, ssrc, encrypt, channel in
            return GroupCallCrypto.shared.transform(data: data,
                                                    ssrc: ssrc,
                                                    encrypt: encrypt,
                                                    channel: channel,
                                                    groupCallId: Int32(groupCallId)) ?? data
        }

        guard bridge.beginGroupCall(withGroupCallId: Int64(groupCallId), conference: true) else {
            stateText = L10n.t("AutoR.766045970e")
            return
        }
        bridge.emitGroupJoinPayload { [weak self] payload, ssrc in
            guard let self else { return }
            self.audioSourceId = Int(ssrc)
            Task { @MainActor in
                do {
                    let joinParameters = GroupCallJoinParameters(audioSourceId: Int(ssrc),
                                                                 isMuted: false,
                                                                 isMyVideoEnabled: false,
                                                                 payload: payload)
                    let response = try await client.joinVideoChat(groupCallId: groupCallId,
                                                                  inviteHash: nil,
                                                                  joinParameters: joinParameters,
                                                                  participantId: nil)
                    bridge.setGroupJoinPayload(response.text)
                    self.stateText = L10n.t("AutoR.180df04346")
                    CallDiag.log("group joined payload=\(response.text.count) chars")
                    await self.reloadParticipants()
                    if video && !self.isVideoEnabled { self.toggleVideo() }
                } catch {
                    CallDiag.log("group join failed \(error)")
                    self.stateText = L10n.t("AutoR.5abf853298")
                    TelegramClient.shared.errorMessage = "Не удалось войти: \(TelegramClient.describe(error))"
                    self.leave()
                }
            }
        }
    }

    func reloadParticipants() async {
        guard let client = TelegramClient.shared.tdClient, groupCallId != 0 else { return }
        _ = try? await client.loadGroupCallParticipants(groupCallId: groupCallId, limit: 100)
        if let call = try? await client.getGroupCall(groupCallId: groupCallId) {
            title = call.title.isEmpty ? title : call.title
        }
    }

    func toggleVideo() {
        isVideoEnabled.toggle()
        if isVideoEnabled && (localView == nil || remoteView == nil) {
            localView = VideoHostView()
            remoteView = VideoHostView()
            localView?.backgroundColor = .black
            remoteView?.backgroundColor = .black
        }
        if isVideoEnabled {
            if let local = localView, let remote = remoteView {
                VoIPBridge.shared().enableGroupVideo(withLocalView: local, remoteView: remote)
            }
            for participant in participants {
                if let endpoint = endpointIds[participant.id] {
                    VoIPBridge.shared().addGroupRemoteVideo(forEndpoint: endpoint)
                }
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        VoIPBridge.shared().setGroupCallMuted(isMuted)
        Task {
            if let client = TelegramClient.shared.tdClient {
                _ = try? await client.toggleGroupCallParticipantIsMuted(groupCallId: groupCallId, isMuted: isMuted, participantId: .messageSenderUser(.init(userId: TelegramClient.shared.me?.id ?? 0)))
            }
        }
    }

    func leave() {
        guard isActive else { return }
        let callId = groupCallId
        isActive = false
        stateText = ""
        isVideoEnabled = false
        localView = nil
        remoteView = nil
        endpointIds.removeAll()
        participants = []
        speakerTitles = []
        VoIPBridge.shared().stopGroupCall()
        isActive = false
        groupCallId = 0
        CallDiag.log("group left id=\(callId)")
        Task {
            if let client = TelegramClient.shared.tdClient {
                _ = try? await client.leaveGroupCall(groupCallId: callId)
            }
        }
    }

    private func updateLevels(_ levels: [NSNumber]) {
        for (index, level) in levels.enumerated() where index < participants.count {
            if let ssrc = ssrcToPeer.first(where: { _ in false })?.key {
                _ = ssrc
            }
            _ = level
        }
        speakerTitles = participants.filter(\.isSpeaking).map(\.name)
    }

    private func fetchAudioPart(timestamp: Int64, duration: Int64) async -> OngoingGroupCallBroadcastPart? {
        guard let client = TelegramClient.shared.tdClient else { return nil }
        do {
            let data = try await client.getGroupCallStreamSegment(channelId: 0,
                                                                  groupCallId: groupCallId,
                                                                  scale: 0,
                                                                  timeOffset: timestamp,
                                                                  videoQuality: nil)
            let decrypted = GroupCallCrypto.shared.transform(data: data.data,
                                                             ssrc: 0,
                                                             encrypt: false,
                                                             channel: 0,
                                                             groupCallId: Int32(groupCallId)) ?? data.data
            return OngoingGroupCallBroadcastPart(timestampMilliseconds: timestamp,
                                                 responseTimestamp: Date().timeIntervalSince1970,
                                                 status: .success,
                                                 oggData: decrypted)
        } catch {
            return nil
        }
    }
}
