import SwiftUI

/// Full-screen UI for a group (video chat) call.
struct GroupCallView: View {
    @ObservedObject private var group = GroupCallManager.shared

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.10, blue: 0.18),
                                    Color(red: 0.03, green: 0.05, blue: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                if group.isVideoEnabled {
                    ZStack(alignment: .topTrailing) {
                        VideoCanvas(uiView: $group.remoteView)
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        VideoCanvas(uiView: $group.localView)
                            .frame(width: 84, height: 118)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(8)
                    }
                    .padding(.horizontal, 16)
                }
                Text(group.title.isEmpty ? "Групповой звонок" : group.title)
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(group.stateText)
                    .font(.appFootnote)
                    .foregroundColor(.white.opacity(0.7))

                Text(String(format: L10n.t("AutoI.7a8c718c39"), ))
                    .font(.appSubheadline)
                    .foregroundColor(.white.opacity(0.85))

                if !group.speakerTitles.isEmpty {
                    Text(L10n.t("Auto.71fb649861") + group.speakerTitles.joined(separator: ", "))
                        .font(.appCaption)
                        .foregroundColor(.green)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(group.participants) { participant in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 30, height: 30)
                                    .overlay(Text(String(participant.name.prefix(1)))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white))
                                Text(participant.name)
                                    .font(.appSubheadline)
                                    .foregroundColor(.white)
                                Spacer()
                                Image(systemName: participant.isMuted ? "mic.slash.fill" : "mic.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(participant.isMuted ? .orange : .green)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(maxHeight: 280)

                HStack(spacing: 30) {
                    Button { group.toggleVideo() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: group.isVideoEnabled ? "video.fill" : "video.slash.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 58, height: 58)
                                .background(Circle().fill(group.isVideoEnabled ? Color.white : Color.white.opacity(0.14)))
                                .foregroundColor(group.isVideoEnabled ? .black : .white)
                            Text(group.isVideoEnabled ? "Видео вкл." : "Видео")
                                .font(.appCaption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)

                    Button { group.toggleMute() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: group.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 58, height: 58)
                                .background(Circle().fill(group.isMuted ? Color.white : Color.white.opacity(0.14)))
                                .foregroundColor(group.isMuted ? .black : .white)
                            Text(group.isMuted ? "Вкл. микрофон" : "Без звука")
                                .font(.appCaption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)

                    Button { group.leave() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 58, height: 58)
                                .background(Circle().fill(Color.red))
                                .foregroundColor(.white)
                            Text(L10n.t("Auto.0f05cf8ab6"))
                                .font(.appCaption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 24)
            }
            .padding(.top, 40)
        }
    }
}

/// Presents the group call screen above the chat UI.
struct GroupCallOverlay: View {
    @ObservedObject private var group = GroupCallManager.shared
    var body: some View {
        if group.isActive {
            GroupCallView()
                .transition(.opacity)
        }
    }
}
