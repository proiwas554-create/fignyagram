import SwiftUI
import UIKit
import TDLibKit

/// Wraps a UIView (tgcalls VideoSampleBufferView) for SwiftUI.
/// Keeps the engine's video view exactly at its own bounds, including after
/// SwiftUI resizes it (video stage resize, call UI minimising, rotation).
final class VideoHostView: UIView {
    var pinsToWindow = false
    private var windowConstraints: [NSLayoutConstraint] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard pinsToWindow else { return }
        NSLayoutConstraint.deactivate(windowConstraints)
        windowConstraints.removeAll()
        guard let window else { return }
        translatesAutoresizingMaskIntoConstraints = false
        windowConstraints = [
            leadingAnchor.constraint(equalTo: window.leadingAnchor),
            trailingAnchor.constraint(equalTo: window.trailingAnchor),
            topAnchor.constraint(equalTo: window.topAnchor),
            bottomAnchor.constraint(equalTo: window.bottomAnchor)
        ]
        NSLayoutConstraint.activate(windowConstraints)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews {
            // Use bounds/center, not frame: the engine view may carry a
            // rotation transform (portrait/landscape) and setting frame on a
            // transformed view produces undefined layout.
            subview.bounds = CGRect(origin: .zero, size: bounds.size)
            subview.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }
}

struct VideoCanvas: UIViewRepresentable {
    @Binding var uiView: UIView?
    /// Pins the host to the window bounds instead of the SwiftUI proposal.
    var fullscreen: Bool = false

    func makeUIView(context: Context) -> UIView {
        let host = VideoHostView()
        host.backgroundColor = .black
        host.pinsToWindow = fullscreen
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        if let uiView, uiView.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            uiView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(uiView)
        }
        host.setNeedsLayout()
        host.layoutIfNeeded()
    }
}

struct CallView: View {
    @ObservedObject private var call = CallManager.shared
    @ObservedObject private var client = TelegramClient.shared

    private var displayName: String {
        !call.peerTitle.isEmpty ? call.peerTitle : "Звонок"
    }

    private var initials: String {
        let letters = displayName.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var isVideoCall: Bool { call.currentCall?.isVideo == true }

    /// Real top inset so controls never sit under the notch/Dynamic Island.
    private var safeTopInset: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return window?.safeAreaInsets.top ?? 47
    }

    var body: some View {
        if call.isMinimized {
            miniCall
        } else {
            fullCall
        }
    }

    /// Compact draggable call window; the call keeps running in background.
    /// For video calls it shows the active stream and tapping it swaps the
    /// streams without expanding.
    private var miniCall: some View {
        let offset = call.pipOffset
        return Group {
            if isVideoCall && (call.localView != nil || call.remoteView != nil) {
                ZStack(alignment: .topTrailing) {
                    VideoCanvas(uiView: call.showSelfAsMain ? $call.localView : $call.remoteView)
                        .frame(width: 110, height: 158)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture { call.swapVideoStreams() }
                    Button { call.expandCall() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 8) {
                        Button { call.toggleMute() } label: {
                            Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        Button { call.toggleSpeaker() } label: {
                            Image(systemName: call.speakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        Button { call.toggleCamera() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        Button { call.swapVideoStreams() } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        Text(call.durationText)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundColor(.white)
                        Button { Task { await TelegramClient.shared.discardCall() } } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.bottom, 6)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            } else {
                VStack(spacing: 2) {
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(
                            Text(initials)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                        )
                        .frame(width: 40, height: 40)
                    Text(displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(call.durationText)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(.white.opacity(0.75))
                    HStack(spacing: 10) {
                        Button { call.toggleMute() } label: {
                            Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        Button { Task { await TelegramClient.shared.discardCall() } } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)
                .frame(width: 92)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.09, green: 0.12, blue: 0.2))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .onTapGesture { call.expandCall() }
            }
        }
        .offset(x: offset.width, y: offset.height)
        .gesture(
            DragGesture()
                .onChanged { value in call.pipOffset = value.translation }
                .onEnded { value in
                    let screen = UIScreen.main.bounds
                    let maxX = max(0, screen.width / 2 - 62)
                    let maxY = max(0, screen.height / 2 - 92)
                    call.pipOffset = CGSize(
                        width: min(max(value.translation.width, -maxX), maxX),
                        height: min(max(value.translation.height, -maxY), maxY)
                    )
                }
        )
    }

    private var fullCall: some View {
        ZStack {
            if isVideoCall {
                videoStage
                    .ignoresSafeArea()
            } else {
                background
            }
            if isVideoCall {
                if call.isChromeHidden {
                    VStack {
                        Spacer()
                        Button { call.toggleChrome() } label: {
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 18)
                    }
                } else {
                    VStack(spacing: 0) {
                        // Top strip: name, state and minimising, nothing over the centre.
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName)
                                    .font(.appHeadline)
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Text(call.stateText)
                                    .font(.appCaption)
                                    .foregroundColor(.white.opacity(0.7))
                                    .lineLimit(1)
                                if !call.callEmojis.isEmpty {
                                    Text(call.callEmojis.joined(separator: " "))
                                        .font(.system(size: 13))
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button { call.minimizeCall() } label: {
                                Image(systemName: "chevron.down.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.white, .black.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, safeTopInset + 6)

                        Spacer(minLength: 0)

                        // Bottom strip: status notices above the controls.
                        callNotice
                            .frame(maxWidth: .infinity)
                        compactControls
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.black.opacity(0.42)))
                            .padding(.bottom, 14)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    header
                    Spacer(minLength: 8)
                    status
                    callNotice
                    Spacer(minLength: 8)
                    controls
                        .padding(.bottom, 18)
                }
                .padding(.horizontal, 20)
            }
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
    }

    /// Single-row controls used for video calls; horizontally scrollable so
    /// they never run past the screen edges on narrow devices.
    private var compactControls: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    iconButton(call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted) { call.toggleMute() }
                    iconButton(call.speakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill", active: call.speakerOn) { call.toggleSpeaker() }
                    iconButton(call.isVideoEnabled ? "video.fill" : "video.slash.fill", active: !call.isVideoEnabled) { call.toggleVideo() }
                    iconButton("arrow.triangle.2.circlepath.camera", active: false) { call.toggleCamera() }
                    iconButton("rotate.right", active: false) { call.rotateVideo() }
            iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", active: call.videoFlipped) { call.flipVideo() }
            iconButton(call.videoFillsScreen ? "rectangle.fill" : "rectangle", active: call.videoFillsScreen) { call.toggleVideoFill() }
                    iconButton("eye.slash.fill", active: false) { call.toggleChrome() }
                }
                .padding(.horizontal, 4)
            }
            Button {
                Task { await client.discardCall() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.red))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func iconButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(0.16)))
                .foregroundColor(active ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pieces

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.10, blue: 0.18),
                         Color(red: 0.03, green: 0.05, blue: 0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: -110, y: -190)
            Circle()
                .fill(Color.blue.opacity(0.22))
                .frame(width: 260, height: 260)
                .blur(radius: 100)
                .offset(x: 120, y: 210)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 96, height: 96)
                if let userId = call.currentCall?.userId {
                    AvatarView(id: userId,
                               title: displayName,
                               photo: call.peerPhoto,
                               size: 96)
                        .clipShape(Circle())
                } else {
                    Text(initials)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))

            Text(displayName)
                .font(.title2.bold())
                .foregroundColor(.white)
                .lineLimit(1)

            Text(call.isIncoming ? "Входящий звонок" : (isVideoCall ? "Видеозвонок" : "Аудиозвонок"))
                .font(.appFootnote)
                .foregroundColor(.white.opacity(0.55))
        }
    }

    /// Full-screen video: the selected stream fills the screen, the other one
    /// sits in a corner. Tapping either side swaps them.
    private var videoStage: some View {
        let screen = UIScreen.main.bounds.size
        return ZStack {
                Color.black

                // The main stream is hosted from the start so its container has a
                // real full-screen size; otherwise it is attached to a 0x0 frame
                // and stays tiny forever.
                VideoCanvas(uiView: call.showSelfAsMain ? $call.localView : $call.remoteView,
                            fullscreen: true)
                    .frame(width: screen.width, height: screen.height)
                    .contentShape(Rectangle())
                    .onTapGesture { call.swapVideoStreams() }

                if !call.remoteVideoActive {
                    VStack(spacing: 12) {
                        if let userId = call.currentCall?.userId {
                            AvatarView(id: userId, title: displayName, photo: call.peerPhoto, size: 110)
                                .clipShape(Circle())
                        }
                        Text(displayName)
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text(call.stateText.isEmpty ? "Соединение…" : call.stateText)
                            .font(.appFootnote)
                            .foregroundColor(.white.opacity(0.65))
                    }
                }

                VStack {
                    HStack {
                        Spacer()
                        VideoCanvas(uiView: call.showSelfAsMain ? $call.remoteView : $call.localView)
                            .frame(width: 104, height: 148)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            )
                            .padding(.top, 96)
                            .padding(.trailing, 14)
                            .opacity(call.isVideoEnabled ? 1 : 0.35)
                            .onTapGesture { call.swapVideoStreams() }
                    }
                    Spacer()
                }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .ignoresSafeArea()
    }

    /// Small in-call notice: peer muted / poor connection.
    @ViewBuilder
    private var callNotice: some View {
        if call.peerMuted {
            noticePill(text: "Собеседник выключил микрофон", icon: "mic.slash.fill", color: .orange)
        } else if call.poorConnection {
            noticePill(text: "Плохая связь", icon: "wifi.exclamationmark", color: .yellow)
        }
    }

    private func noticePill(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.appCaption)
        }
        .foregroundColor(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .padding(.top, 6)
    }

    private var status: some View {
        VStack(spacing: 8) {
            if call.audioStarted {
                Text(call.durationText)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            } else {
                Text(call.stateText)
                    .font(.appFootnote)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 22) {
            HStack(spacing: 26) {
                controlButton(
                    icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                    title: call.isMuted ? "Вкл. микрофон" : "Без звука",
                    active: call.isMuted
                ) { call.toggleMute() }

                controlButton(
                    icon: call.speakerOn ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                    title: "Динамик",
                    active: call.speakerOn
                ) { call.toggleSpeaker() }

                if isVideoCall {
                    controlButton(
                        icon: call.isVideoEnabled ? "video.fill" : "video.slash.fill",
                        title: "Видео",
                        active: call.isVideoEnabled
                    ) { call.toggleVideo() }
                    controlButton(
                        icon: "eye.slash.fill",
                        title: "Скрыть",
                        active: false
                    ) { call.toggleChrome() }
                    controlButton(
                        icon: "arrow.triangle.2.circlepath.camera",
                        title: "Камера",
                        active: false
                    ) { call.toggleCamera() }
                }
            }

            HStack(spacing: 18) {
                if !call.isIncoming || call.hasAccepted {
                    controlButton(icon: "chevron.down", title: "Свернуть", active: false) {
                        call.minimizeCall()
                    }
                }
                if call.isIncoming && !call.hasAccepted {
                    actionCircle(icon: "phone.down.fill", color: .red, size: 62) {
                        Task { await client.discardCall() }
                    }
                    actionCircle(icon: "phone.fill", color: .green, size: 62) {
                        Task { await client.acceptCall() }
                    }
                } else {
                    actionCircle(icon: "phone.down.fill", color: .red, size: 62) {
                        Task { await client.discardCall() }
                    }
                }
            }
        }
    }

    private func controlButton(icon: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(
                        Circle().fill(active ? Color.white : Color.white.opacity(0.12))
                    )
                    .foregroundColor(active ? .black : .white)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
    }

    private func actionCircle(icon: String, color: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .background(Circle().fill(color))
                .foregroundColor(.white)
                .shadow(color: color.opacity(0.45), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
    }
}

/// Small avatar helper: shows the peer's photo when available.
