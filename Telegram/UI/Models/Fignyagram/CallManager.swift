import Foundation
import Combine
import UIKit
import AVFoundation
import TDLibKit

/// Call signaling + media bridge. TDLib provides the signaling and the
/// encryption key/endpoints; VoIPBridge (tgcalls) carries audio/video.
@MainActor
final class CallManager: ObservableObject {
    static let shared = CallManager()

    @Published private(set) var currentCall: Call?
    @Published private(set) var stateText = ""
    @Published private(set) var audioStarted = false
    @Published private(set) var isMuted = false
    @Published private(set) var isVideoEnabled = true
    @Published private(set) var speakerOn = false
    @Published private(set) var durationText = "00:00"
    @Published private(set) var needsRetry = false
    @Published private(set) var peerTitle = ""
    @Published private(set) var isIncoming = false
    @Published private(set) var hasAccepted = false
    @Published var isMinimized = false
    @Published var pipOffset: CGSize = .zero
    /// When true the big stage shows the local camera instead of the peer.
    @Published var showSelfAsMain = false
    /// Hides every control so only the video streams stay on screen.
    @Published var isChromeHidden = false
    @Published private(set) var videoRotation = 0
    @Published private(set) var videoFlipped = false
    @Published private(set) var videoFillsScreen = false
    @Published private(set) var errorText: String?
    @Published private(set) var peerMuted = false
    @Published private(set) var poorConnection = false
    @Published private(set) var signalBars = 4
    @Published private(set) var remoteVideoActive = false {
        didSet {
            guard remoteVideoActive != oldValue else { return }
            DispatchQueue.main.async { [weak self] in self?.refreshVideoHosts() }
        }
    }
    @Published private(set) var localPreviewActive = false
    /// Emoji fingerprint of the call's encryption key (shown in call info).
    @Published private(set) var callEmojis: [String] = []

    /// Video canvases owned by CallView (local camera / remote peer).
    @Published var localView: UIView?
    @Published var remoteView: UIView?

    func setStatus(_ text: String) { stateText = text }

    /// Call participant's avatar, resolved from the loaded user record.
    var peerPhoto: ChatPhotoInfo? {
        guard let userId = currentCall?.userId,
              let user = ChatStore.shared.users[userId],
              let photo = user.profilePhoto else { return nil }
        return ChatPhotoInfo(big: photo.big,
                             hasAnimation: photo.hasAnimation,
                             isPersonal: photo.isPersonal,
                             minithumbnail: photo.minithumbnail,
                             small: photo.small)
    }

    func markAccepted() {
        hasAccepted = true
    }

    private var keyExchangeWatchdog: Task<Void, Never>?

    /// TDLib stays in callStateExchangingKeys until the media engine answers.
    /// Without the linked tgcalls/WebRTC module the call can hang there, so we
    /// surface a clear message instead of an endless "Обмен ключами…".
    private func watchKeyExchange() {
        keyExchangeWatchdog?.cancel()
        keyExchangeWatchdog = Task { [weak self] in
            // Do NOT re-send acceptCall here: repeating accept while TDLib is
            // performing its DH exchange can reset the call actor state.
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard !Task.isCancelled, let strongSelf = self else { return }
            if case .callStateExchangingKeys = strongSelf.currentCall?.state {
                strongSelf.needsRetry = false
                strongSelf.stateText = "Обмен ключами не завершился"
                CallDiag.log("key exchange stuck for 14s callId=\(strongSelf.currentCall?.id ?? -1)")
            }
        }
    }

    private func cancelWatchdog() {
        keyExchangeWatchdog?.cancel()
        keyExchangeWatchdog = nil
    }

    private var signalingInCount = 0
    private var pendingSignaling: [Data] = []
    private var signalingOutCount = 0

    func handleSignalingData(callId: Int, data: Data) {
        guard currentCall?.id == callId else {
            CallDiag.log("signaling.in ignored: callId=\(callId) current=\(currentCall?.id ?? -1)")
            return
        }
        signalingInCount += 1
        CallDiag.log("signaling.in #\(signalingInCount) bytes=\(data.count) engineReady=\(audioStarted)")
        if audioStarted {
            VoIPBridge.shared().receiveSignaling(data)
        } else {
            // The peer can start sending as soon as its engine is ready, while
            // our engine is still being created; keep the packets so the
            // handshake is not lost.
            pendingSignaling.append(data)
            if pendingSignaling.count > 64 { pendingSignaling.removeFirst() }
        }
    }

    func handle(_ update: Update) {
        guard case .updateCall(let u) = update else { return }
        CallDiag.log("updateCall id=\(u.call.id) outgoing=\(u.call.isOutgoing) video=\(u.call.isVideo) state=\(Self.stateName(u.call.state))")
        currentCall = u.call
        isIncoming = !u.call.isOutgoing
        if case .callStatePending = u.call.state {
            // still ringing
        } else {
            hasAccepted = true
        }
        if let user = ChatStore.shared.users[u.call.userId] {
            peerTitle = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        }
        if u.call.state is CallState {
            stateText = Self.text(u.call.state)
        }
        if case .callStateExchangingKeys = u.call.state {
            watchKeyExchange()
        } else {
            cancelWatchdog()
        }
        if case .callStateReady(let ready) = u.call.state {
            self.callEmojis = ready.emojis
            CallDiag.log("READY keyBytes=\(ready.encryptionKey.count) servers=\(ready.servers.count) p2p=\(ready.allowP2p) versions=\(ready.protocol.libraryVersions.joined(separator: ",")) maxLayer=\(ready.protocol.maxLayer) configChars=\(ready.config.count) customChars=\(ready.customParameters.count)")
            startAudio(ready, outgoing: u.call.isOutgoing)
        }
        if u.call.id != currentCall?.id,
           case .callStateDiscarded = u.call.state {
            CallDiag.log("discarded update for stale call id=\(u.call.id)")
            Task.detached(priority: .userInitiated) {
                VoIPBridge.shared().stopCall()
            }
            audioStarted = false
        }
        if case .callStateDiscarded(let d) = u.call.state {
            CallDiag.log("DISCARDED reason=\(Self.discardReasonName(d.reason)) needLog=\(d.needLog) needDebug=\(d.needDebugInformation)")
            tearDown()
        }
        if case .callStateError(let e) = u.call.state {
            CallDiag.log("CALL ERROR code=\(e.error.code) message=\(e.error.message)")
            errorText = e.error.message
            if e.error.code == 4005000 {
                TelegramClient.shared.errorMessage = "Звонок не состоялся: собеседник не ответил"
            } else {
                TelegramClient.shared.errorMessage = "Звонок завершился: \(e.error.message)"
            }
            tearDown()
        }
    }

    /// Feeds TDLib CallStateReady into tgcalls through VoIPBridge.
    private func startAudio(_ ready: CallStateReady, outgoing: Bool) {
        var servers: [[String: Any]] = []
        for server in ready.servers {
            var dict: [String: Any] = [:]
            dict["id"] = server.id
            dict["ipv4"] = server.ipAddress
            dict["ipv6"] = server.ipv6Address
            dict["port"] = server.port
            switch server.type {
            case .callServerTypeTelegramReflector(let reflector):
                dict["tcp"] = reflector.isTcp
                dict["peerTag"] = reflector.peerTag
            case .callServerTypeWebrtc(let rtc):
                dict["rtc"] = true
                dict["supportsStun"] = rtc.supportsStun
                dict["supportsTurn"] = rtc.supportsTurn
                dict["username"] = rtc.username
                dict["password"] = rtc.password
            }
            servers.append(dict)
        }
        startEngine(encryptionKey: ready.encryptionKey,
                    config: ready.config,
                    customParameters: ready.customParameters,
                    allowP2p: ready.allowP2p,
                    servers: servers,
                    versions: ready.protocol.libraryVersions,
                    maxLayer: Int32(ready.protocol.maxLayer),
                    isVideo: currentCall?.isVideo ?? false,
                    outgoing: outgoing)
    }

    /// The engine records silence unless microphone access has been granted, so
    /// ask for it (once) before creating the media context, and verify that the
    /// hardware actually produces samples.
    private func startEngine(encryptionKey: Data,
                             config: String,
                             customParameters: String,
                             allowP2p: Bool,
                             servers: [[String: Any]],
                             versions: [String],
                             maxLayer: Int32,
                             isVideo: Bool,
                             outgoing: Bool) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            CallDiag.log("microphone permission granted")
            beginEngine(encryptionKey: encryptionKey, config: config,
                           customParameters: customParameters, allowP2p: allowP2p,
                           servers: servers, versions: versions, maxLayer: maxLayer,
                           isVideo: isVideo, outgoing: outgoing)
        case .denied:
            CallDiag.log("microphone permission denied")
            stateText = "Нет доступа к микрофону"
            TelegramClient.shared.errorMessage = "Нет доступа к микрофону: разрешите его в Настройках"
        default:
            CallDiag.log("microphone permission requested")
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    CallDiag.log("microphone permission result=\(granted)")
                    guard let self else { return }
                    if granted {
                        self.beginEngine(encryptionKey: encryptionKey, config: config,
                                            customParameters: customParameters, allowP2p: allowP2p,
                                            servers: servers, versions: versions, maxLayer: maxLayer,
                                            isVideo: isVideo, outgoing: outgoing)
                    } else {
                        self.stateText = "Нет доступа к микрофону"
                        TelegramClient.shared.errorMessage = "Нет доступа к микрофону: разрешите его в Настройках"
                    }
                }
            }
        }
    }

    private func beginEngine(encryptionKey: Data,
                                config: String,
                                customParameters: String,
                                allowP2p: Bool,
                                servers: [[String: Any]],
                                versions: [String],
                                maxLayer: Int32,
                                isVideo: Bool,
                                outgoing: Bool) {
        // Note: a temporary AVAudioEngine probe used to run here. It competed
        // for the audio input with the media engine (engine captured silence
        // while the probe measured a normal level), so it must not run in the
        // production path.
        performEngineStart(encryptionKey: encryptionKey, config: config,
                           customParameters: customParameters, allowP2p: allowP2p,
                           servers: servers, versions: versions, maxLayer: maxLayer,
                           isVideo: isVideo, outgoing: outgoing)
    }

    private func performEngineStart(encryptionKey: Data,
                             config: String,
                             customParameters: String,
                             allowP2p: Bool,
                             servers: [[String: Any]],
                             versions: [String],
                             maxLayer: Int32,
                             isVideo: Bool,
                             outgoing: Bool) {
        guard !audioStarted else { return }

        // SOCKS5 proxy (optional): external proxy configured in Settings.
        // The built-in local listener (1443) is MTProto/WS, NOT SOCKS5.
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "socksProxyHost") ?? ""
        let port = UInt16(defaults.integer(forKey: "socksProxyPort"))
        let user = defaults.string(forKey: "socksProxyUser") ?? ""
        let pass = defaults.string(forKey: "socksProxyPassword") ?? ""
        if !host.isEmpty, port > 0 {
            VoIPBridge.shared().configureProxy(withHost: host, port: port,
                                             username: user, password: pass)
        }

        // Activate the shared session *before* the engine creates its audio
        // unit: a unit started while the session is inactive never captures or
        // plays, which showed up as level=0 with remoteAudio=1.
        activateAudioSessionForCall()

        VoIPBridge.shared().configureCall(
            withServerConfig: config,
            customParameters: customParameters,
            allowP2P: allowP2p,
            maxLayer: maxLayer,
            libraryVersions: versions
        )

        if let callId = currentCall?.id {
            VoIPBridge.shared().signalingDataHandler = { [weak self] data in
                DispatchQueue.main.async {
                    self?.signalingOutCount += 1
                    CallDiag.log("signaling.out #\(self?.signalingOutCount ?? -1) bytes=\(data.count)")
                    TelegramClient.shared.sendCallSignalingData(
                        callId: callId,
                        data: data
                    )
                }
            }
        }

        VoIPBridge.shared().remoteVideoFirstFrameHandler = { [weak self] in
            guard let self else { return }
            self.remoteVideoActive = true
            CallDiag.log("remote video first frame")
        }
        VoIPBridge.shared().localVideoFirstFrameHandler = { [weak self] in
            guard let self else { return }
            self.localPreviewActive = true
            CallDiag.log("local video first frame")
        }
        VoIPBridge.shared().remoteAudioHandler = { [weak self] muted in
            guard let self else { return }
            if self.peerMuted != muted { CallDiag.log("peer muted=\(muted)") }
            self.peerMuted = muted
        }
        VoIPBridge.shared().signalBarsHandler = { [weak self] bars in
            guard let self else { return }
            self.signalBars = Int(bars)
            if bars <= 1 { self.poorConnection = true }
        }

        // Engine states flow into the UI and start the call timer on connect.
        VoIPBridge.shared().stateHandler = { [weak self] state in
            guard let self else { return }
            CallDiag.log("ui engine state=\(state) audioStarted=\(self.audioStarted)")
            switch state {
            case 1: // OngoingCallStateConnected
                self.poorConnection = false
                self.audioStarted = true
                if !self.durationStarted {
                    self.durationStarted = true
                    self.startDurationTimer()
                    CallDiag.log("timer started")
                }
                self.stateText = "Звонок подключён"
            case 2: // OngoingCallStateFailed
                self.stateText = "Ошибка соединения"
                self.needsRetry = false
                // End locally without blocking the main thread; the detached
                // teardown also discards the TDLib call.
                self.tearDown()
            case 3: // OngoingCallStateReconnecting
                // Never stop the engine here: stopCall() blocks and this
                // callback runs on the main thread, which froze the call UI.
                CallDiag.log("engine reconnecting")
                self.poorConnection = true
                self.stateText = "Переподключение…"
            default:
                break
            }
        }

        videoRotation = UserDefaults.standard.integer(forKey: "videoRotationOffset")
        // Correct on this device without extra mirroring: flipping made the
        // frame look mirrored/upside down.
        if !UserDefaults.standard.bool(forKey: "videoFlipResetDone") {
            UserDefaults.standard.set(true, forKey: "videoFlipResetDone")
            UserDefaults.standard.set(false, forKey: "videoFlip")
        }
        videoFlipped = UserDefaults.standard.bool(forKey: "videoFlip")
        if !UserDefaults.standard.bool(forKey: "videoFillResetDone") {
            UserDefaults.standard.set(true, forKey: "videoFillResetDone")
            UserDefaults.standard.set(true, forKey: "videoFillsScreen")
        }
        // Local display only: fills the screen in Fignyagram without touching
        // the outgoing stream, so the peer's view stays exactly as before.
        videoFillsScreen = (UserDefaults.standard.object(forKey: "videoFillsScreen") as? Bool) ?? true
        let wantsVideo = isVideo
        if wantsVideo {
            // The engine installs its own video subviews into these containers.
            if localView == nil { localView = VideoHostView() }
            if remoteView == nil { remoteView = VideoHostView() }
            localView?.backgroundColor = .black
            remoteView?.backgroundColor = .black
        }
        CallDiag.log("engine.start attempt video=\(wantsVideo) servers=\(servers.count)")
        // Engine construction performs audio-session setup and WebRTC thread
        // creation; doing it on the main thread froze the call UI right after
        // callStateReady (the screen stayed at "Обмен ключами…").
        let isVideo = wantsVideo
        let localCanvas = localView
        let remoteCanvas = remoteView
        Task.detached(priority: .userInitiated) {
            let started = VoIPBridge.shared().startCall(
                withKey: encryptionKey,
                isOutgoing: outgoing,
                isVideo: isVideo,
                servers: servers,
                localView: localCanvas,
                remoteView: remoteCanvas
            )
            let bridgeState = VoIPBridge.shared().stateText
            await MainActor.run {
                CallDiag.log("engine.start result=\(started) state=\(bridgeState) bufferedSignaling=\(self.pendingSignaling.count)")
                self.audioStarted = started
                        self.activateAudioSessionForCall()
                self.logAudioSession()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.logAudioSession()
                }
                if started {
                    for packet in self.pendingSignaling {
                        VoIPBridge.shared().receiveSignaling(packet)
                    }
                    self.pendingSignaling.removeAll()
                    self.stateText = bridgeState
                } else {
                    self.stateText = "Не удалось запустить аудио-модуль"
                }
            }
        }
    }

    /// Fallback used when TDLibKit's generated models cannot decode an
    /// `updateCall` (the TDLibFramework build can be newer than the models).
    /// Without this the `callStateReady` update is dropped silently, the UI
    /// stays at "Обмен ключами…" and the media engine is never started even
    /// though the peer is already sending signaling data.
    func handleRawCallUpdate(_ json: [String: Any]) {
        guard let call = json["call"] as? [String: Any] else { return }
        let callId = call["id"] as? Int ?? 0
        let isOutgoing = call["is_outgoing"] as? Bool ?? true
        let isVideo = call["is_video"] as? Bool ?? false
        guard let state = call["state"] as? [String: Any],
              let stateType = state["@type"] as? String else { return }

        CallDiag.log("raw updateCall id=\(callId) outgoing=\(isOutgoing) video=\(isVideo) state=\(stateType)")

        if stateType == "callStateDiscarded" || stateType == "callStateError" {
            let message = (state["error"] as? [String: Any])?["message"] as? String ?? stateType
            CallDiag.log("raw call end: \(message)")
            TelegramClient.shared.errorMessage = "Звонок завершился: \(message)"
            tearDown()
            return
        }
        guard stateType == "callStateReady" else {
            if stateType == "callStateExchangingKeys" { hasAccepted = true }
            return
        }

        guard let keyBase64 = state["encryption_key"] as? String,
              let key = Data(base64Encoded: keyBase64) else {
            CallDiag.log("raw ready: cannot read encryption_key")
            return
        }
        let protocolInfo = state["protocol"] as? [String: Any] ?? [:]
        let versions = protocolInfo["library_versions"] as? [String] ?? []
        let maxLayer = protocolInfo["max_layer"] as? Int ?? 92
        let allowP2p = state["allow_p2p"] as? Bool ?? false
        let config = state["config"] as? String ?? ""
        let custom = state["custom_parameters"] as? String ?? ""

        var servers: [[String: Any]] = []
        for item in (state["servers"] as? [[String: Any]] ?? []) {
            var dict: [String: Any] = [:]
            dict["id"] = item["id"] ?? 0
            dict["ipv4"] = item["ip_address"] ?? ""
            dict["ipv6"] = item["ipv6_address"] ?? ""
            dict["port"] = item["port"] ?? 0
            let type = item["type"] as? [String: Any] ?? [:]
            let typeName = type["@type"] as? String ?? ""
            if typeName == "callServerTypeWebrtc" {
                dict["rtc"] = true
                dict["supportsStun"] = type["supports_stun"] ?? false
                dict["supportsTurn"] = type["supports_turn"] ?? false
                dict["username"] = type["username"] ?? ""
                dict["password"] = type["password"] ?? ""
            } else {
                dict["tcp"] = type["is_tcp"] ?? false
                dict["peerTag"] = type["peer_tag"] ?? ""
            }
            servers.append(dict)
        }

        if let emojis = state["emojis"] as? [String] { callEmojis = emojis }
        CallDiag.log("raw READY keyBytes=\(key.count) servers=\(servers.count) versions=\(versions.joined(separator: ",")) maxLayer=\(maxLayer) configChars=\(config.count)")
        hasAccepted = true
        startEngine(encryptionKey: key,
                    config: config,
                    customParameters: custom,
                    allowP2p: allowP2p,
                    servers: servers,
                    versions: versions,
                    maxLayer: Int32(maxLayer),
                    isVideo: isVideo,
                    outgoing: isOutgoing)
    }

    /// The engine's ADM can end up running in a deactivated AVAudioSession
    /// (observed on iOS 27: remoteAudio=1, level=0, silence in both
    /// directions). Activating the shared session explicitly restores both
    /// capture and playback.
    private func lockCallOrientation() {
        if #available(iOS 16.0, *) {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }

    private func activateAudioSessionForCall() {
        let session = AVAudioSession.sharedInstance()
        var failure: String?
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            failure = String(describing: error)
        }
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let active = (session as AnyObject).value(forKey: "isActive") as? Bool ?? false
        CallDiag.log("activate session failure=\(failure ?? "none") active=\(active) inputs=\(inputs) outputs=\(outputs)")
        if speakerOn {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    private func logAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        CallDiag.log("audio session category=\(session.category.rawValue) mode=\(session.mode.rawValue) active=\(session.isOtherAudioPlaying) sampleRate=\(session.sampleRate) io=\(session.ioBufferDuration) outputs=\(outputs) volume=\(session.outputVolume)")
    }

    private func tearDown() {
        guard !isTearingDown else { return }
        isTearingDown = true
        defer { isTearingDown = false }
        removeFullScreenVideoHost()
        let callId = currentCall?.id
        CallDiag.log("teardown callId=\(callId ?? -1)")
        localView = nil
        remoteView = nil
        hasAccepted = false
        durationStarted = false
        durationTimer?.cancel()
        durationText = "00:00"
        isMinimized = false
        pipOffset = .zero
        pendingSignaling.removeAll()
        Task.detached(priority: .userInitiated) {
            VoIPBridge.shared().stopCall()
            if let callId {
                await TelegramClient.shared.discardCall(callId: callId)
            }
        }
        audioStarted = false
        currentCall = nil
        stateText = ""
    }

    private var durationTimer: Task<Void, Never>?
    private var durationStarted = false
    private var isTearingDown = false
    private var videoContainer: UIView?
    private weak var hostedFullScreenVideo: UIView?

    private func startDurationTimer() {
        durationTimer?.cancel()
        let started = Date()
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let strongSelf = self, !Task.isCancelled else { return }
                let seconds = Int(Date().timeIntervalSince(started))
                let text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                if strongSelf.durationText != text { strongSelf.durationText = text }
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.cancel()
        durationTimer = nil
        durationText = "00:00"
    }

    func retryConnection() {
        needsRetry = false
        stateText = "Соединение…"
        CallDiag.log("retry requested callId=\(currentCall?.id ?? -1) outgoing=\(currentCall?.isOutgoing ?? false)")
        if currentCall?.isOutgoing == false {
            Task { await TelegramClient.shared.acceptCall() }
        }
        watchKeyExchange()
    }

    func minimizeCall() {
        isMinimized = true
        CallDiag.log("call minimized")
    }

    func expandCall() {
        isMinimized = false
        pipOffset = .zero
        CallDiag.log("call expanded")
    }

    func toggleChrome() {
        isChromeHidden.toggle()
        CallDiag.log("call chrome hidden=\(isChromeHidden)")
    }

    func rotateVideo() {
        videoRotation = (videoRotation + 1) % 4
        UserDefaults.standard.set(videoRotation, forKey: "videoRotationOffset")
        VoIPBridge.shared().setVideoRotationOffset(videoRotation)
        CallDiag.log("video rotation offset=\(videoRotation)")
    }

    func toggleVideoFill() {
        videoFillsScreen.toggle()
        UserDefaults.standard.set(videoFillsScreen, forKey: "videoFillsScreen")
        VoIPBridge.shared().setVideoFillsScreen(videoFillsScreen)
        CallDiag.log("video fillsScreen=\(videoFillsScreen)")
    }

    func flipVideo() {
        videoFlipped.toggle()
        UserDefaults.standard.set(videoFlipped, forKey: "videoFlip")
        VoIPBridge.shared().setVideoFlip(videoFlipped)
        CallDiag.log("video flip=\(videoFlipped)")
    }

    /// Hosts the selected stream in a window-level view sized to the screen, so
    /// it can never be constrained by a SwiftUI layout proposal.
    func updateFullScreenVideoHost() {
        guard currentCall?.isVideo == true, let window = Self.keyWindow() else { return }
        let container: UIView
        if let existing = videoContainer {
            container = existing
        } else {
            container = UIView(frame: window.bounds)
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.backgroundColor = .black
            container.isUserInteractionEnabled = false
            window.insertSubview(container, at: 0)
            videoContainer = container
        }
        container.frame = window.bounds
        let desired = showSelfAsMain ? localView : remoteView
        guard let desired else { return }
        if hostedFullScreenVideo !== desired {
            hostedFullScreenVideo?.removeFromSuperview()
            desired.removeFromSuperview()
            desired.frame = container.bounds
            desired.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(desired)
            hostedFullScreenVideo = desired
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }

    private func removeFullScreenVideoHost() {
        hostedFullScreenVideo?.removeFromSuperview()
        hostedFullScreenVideo = nil
        videoContainer?.removeFromSuperview()
        videoContainer = nil
    }

    /// Re-installs render views after SwiftUI creates their containers.
    func refreshVideoHosts() {
        for view in [localView, remoteView].compactMap({ $0 }) {
            guard let superview = view.superview else { continue }
            view.frame = superview.bounds
            view.setNeedsLayout()
            superview.setNeedsLayout()
        }
    }

    func swapVideoStreams() {
        showSelfAsMain.toggle()
        CallDiag.log("video swapped selfAsMain=\(showSelfAsMain)")
    }

    func movePip(by translation: CGSize) {
        pipOffset = translation
    }

    func toggleSpeaker() {
        speakerOn.toggle()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(speakerOn ? .speaker : .none)
            CallDiag.log("speaker route speaker=\(speakerOn)")
        } catch {
            CallDiag.log("speaker route FAILED \(error)")
        }
    }

    func toggleVideo() {
        isVideoEnabled.toggle()
        VoIPBridge.shared().setVideoEnabled(isVideoEnabled)
    }

    func toggleCamera() {
        VoIPBridge.shared().switchCamera()
    }

    func toggleMute() {
        isMuted.toggle()
        VoIPBridge.shared().setMicMute(isMuted)
    }

    static func discardReasonName(_ reason: CallDiscardReason) -> String {
        switch reason {
        case .callDiscardReasonEmpty: return "empty"
        case .callDiscardReasonMissed: return "missed"
        case .callDiscardReasonDeclined: return "declined"
        case .callDiscardReasonDisconnected: return "disconnected"
        case .callDiscardReasonHungUp: return "hungUp"
        default: return "other"
        }
    }

    static func stateName(_ state: CallState) -> String {
        switch state {
        case .callStatePending: return "pending"
        case .callStateExchangingKeys: return "exchangingKeys"
        case .callStateReady: return "ready"
        case .callStateHangingUp: return "hangingUp"
        case .callStateDiscarded: return "discarded"
        case .callStateError: return "error"
        default: return "other"
        }
    }

    static func text(_ state: CallState) -> String {
        switch state {
        case .callStatePending: return "Соединение…"
        case .callStateExchangingKeys: return "Обмен ключами…"
        case .callStateReady: return "Соединение…"
        case .callStateHangingUp: return "Завершение…"
        case .callStateDiscarded: return "Завершено"
        case .callStateError: return "Ошибка звонка"
        default: return "…"
        }
    }
}
