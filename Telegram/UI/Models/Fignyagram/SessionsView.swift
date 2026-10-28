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
                                    Text("это устройство")
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
                                    Label("Завершить сессию", systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        confirmTerminateAll = true
                    } label: {
                        Label("Завершить все другие сессии", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Устройства")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .confirmationDialog("Завершить все другие сессии?", isPresented: $confirmTerminateAll, titleVisibility: .visible) {
                Button("Завершить", role: .destructive) {
                    Task {
                        try? await client.terminateOtherSessions()
                        await reload()
                    }
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text("Все устройства, кроме этого, будут разлогинены.")
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
