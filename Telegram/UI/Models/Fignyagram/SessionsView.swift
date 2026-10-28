import SwiftUI
import TDLibKit

/// Active Telegram sessions (devices), like Settings → Devices in Telegram.
struct SessionsView: View {
    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [Session] = []
    @State private var isLoading = true
    @State private var confirmTerminateAll = false

    var body: some View {
        NavigationView {
            List {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(session.deviceModel.isEmpty ? session.applicationName : session.deviceModel)
                                    .font(.appHeadline)
                                if session.isCurrent {
                                    Text(L10n.t("Auto.75f8aea5aa"))
                                        .font(.appCaption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                        .foregroundColor(.accentColor)
                                }
                                Spacer()
                            }
                            Text("\(session.applicationName) \(session.applicationVersion)")
                                .font(.appCaption).foregroundColor(.secondary)
                            if !session.location.isEmpty {
                                Text(session.location).font(.appCaption).foregroundColor(.secondary)
                            }
                            Text(Date(timeIntervalSince1970: TimeInterval(session.lastActiveDate)), style: .relative)
                                .font(.appCaption2).foregroundColor(.secondary)
                        }
                        .contextMenu {
                            if !session.isCurrent {
                                Button(role: .destructive) {
                                    Task {
                                        try? await client.terminateSession(session.id)
                                        await reload()
                                    }
                                } label: {
                                    Label(L10n.t("Auto.dd1975906b"), systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmTerminateAll = true
                    } label: {
                        Label(L10n.t("Auto.11b067d1d2"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle(L10n.t("Auto.5172b9d52e"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .confirmationDialog(L10n.t("Auto.8b3d82f340"), isPresented: $confirmTerminateAll, titleVisibility: .visible) {
                Button(L10n.t("Auto.b0e3a5e058"), role: .destructive) {
                    Task {
                        try? await client.terminateOtherSessions()
                        await reload()
                    }
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t("Auto.9d8c631cbf"))
            }
            .task { await reload() }
        }
        .navigationViewStyle(.stack)
    }

    private func reload() async {
        isLoading = true
        sessions = await client.activeSessions()
        isLoading = false
    }
}
