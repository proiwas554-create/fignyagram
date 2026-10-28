import SwiftUI

/// Settings for the built-in local MTProto-over-WebSocket proxy.
struct ProxySettingsView: View {
    @ObservedObject private var proxy = BuiltInProxyManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var externalServer = ""
    @State private var externalPort = "443"
    @State private var externalSecret = ""
    @State private var externalError: String?
    @ObservedObject private var vpnKeys = VPNKeyStore.shared
    @State private var vpnKeyInput = ""
    @State private var vpnKeyMessage: String?
    @AppStorage("cfProxyDomain") private var cfProxyDomain = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle(L10n.t("Auto.ea3f897602"), isOn: Binding(
                        get: { proxy.isEnabled },
                        set: { proxy.setEnabled($0) }
                    ))
                    HStack {
                        Text(L10n.t("Auto.7203f7a4ff"))
                        Spacer()
                        Text(proxy.status)
                            .foregroundColor(statusColor)
                    }
                    HStack {
                        Text(L10n.t("Auto.80148fa5ad"))
                        Spacer()
                        Text("\(proxy.host):\(proxy.port)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                } footer: {
                    Text(L10n.t("Auto.58ef8f1b55"))
                        .font(.appFootnote)
                }

                if proxy.health == .directFallback {
                    Section {
                        Text(L10n.t("Auto.ecb5a83403"))
                            .font(.appFootnote)
                            .foregroundColor(.orange)
                    }
                }

                if let error = proxy.lastError {
                    Section {
                        Text(error)
                            .font(.appFootnote)
                            .foregroundColor(.red)
                    }
                }

                Section {
                    TextField(L10n.t("Auto.b71a93fe03"), text: $cfProxyDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(L10n.t("Auto.8195122655")) {
                        proxy.restart()
                    }
                } header: {
                    Text(L10n.t("Auto.468ccab82d"))
                } footer: {
                    Text(L10n.t("Auto.088bcce067"))
                        .font(.appFootnote)
                }

                Section {
                    Button(L10n.t("Auto.23ac877659")) {
                        proxy.restart()
                    }
                    .disabled(!proxy.isEnabled)
                } footer: {
                    Text(L10n.t("Auto.8bf265db3b"))
                        .font(.appFootnote)
                }

                Section {
                    Text(L10n.t("Auto.096027824a"))
                        .font(.appHeadline)
                    TextField(L10n.t("Auto.58a3058697"), text: $externalServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.t("Auto.8964d94a1b"), text: $externalPort)
                        .keyboardType(.numberPad)
                    TextField(L10n.t("Auto.5be5d37eb8"), text: $externalSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(L10n.t("Auto.9fb3aee2a6")) {
                        connectExternal()
                    }
                    .disabled(externalServer.isEmpty || externalSecret.isEmpty)
                    if let externalError {
                        Text(externalError)
                            .font(.appFootnote)
                            .foregroundColor(.red)
                    }
                    Button(L10n.t("Auto.0c013a6ba3"), role: .destructive) {
                        proxy.setEnabled(false)
                        Task { await TelegramClient.shared.disableAllProxies() }
                    }
                } header: {
                    Text(L10n.t("Auto.3e88bd6b62"))
                } footer: {
                    Text(L10n.t("Auto.9e39e64e42"))
                        .font(.appFootnote)
                }

                Section {
                    TextField(L10n.t("Auto.79d810398a"), text: $vpnKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(L10n.t("Auto.b2f9091164")) {
                        if vpnKeys.add(vpnKeyInput) {
                            vpnKeyInput = ""
                            vpnKeyMessage = "Ключ сохранён"
                        } else {
                            vpnKeyMessage = "Пустой или уже добавленный ключ"
                        }
                    }
                    .disabled(vpnKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let vpnKeyMessage {
                        Text(vpnKeyMessage).font(.appCaption).foregroundColor(.secondary)
                    }
                    ForEach(vpnKeys.keys) { key in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(key.title).font(.caption.bold())
                            HStack(spacing: 10) {
                                Button(L10n.t("Auto.112b141bc7")) {
                                    UIPasteboard.general.string = key.raw
                                }
                                if key.mtproto != nil {
                                    Button(L10n.t("Auto.ad5c2ce8c2")) {
                                        connectVPNKey(key)
                                    }
                                }
                                Button(L10n.t("Common.Delete"), role: .destructive) {
                                    vpnKeys.remove(key)
                                }
                            }
                            .font(.appCaption)
                        }
                    }
                } header: {
                    Text(L10n.t("Auto.c3b49ab87c"))
                } footer: {
                    Text(L10n.t("Auto.e08c99052e"))
                        .font(.appFootnote)
                }

                Section {
                    Text(L10n.t("Auto.386d4adfab"))
                        .font(.appCaption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("Common.Proxy"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func connectVPNKey(_ key: VPNKey) {
        guard let mtproto = key.mtproto else {
            vpnKeyMessage = "Этот формат нельзя подключить внутри приложения"
            return
        }
        externalServer = mtproto.server
        externalPort = String(mtproto.port)
        externalSecret = mtproto.secret
        connectExternal()
    }

    private func connectExternal() {
        let port = Int(externalPort) ?? 443
        externalError = nil
        proxy.setEnabled(false)
        Task {
            do {
                try await TelegramClient.shared.activateExternalProxy(
                    server: externalServer,
                    port: port,
                    secret: externalSecret
                )
            } catch {
                externalError = TelegramClient.describe(error)
            }
        }
    }

    private var statusColor: Color {
        switch proxy.health {
        case .webSocket, .cloudflare: return .green
        case .directFallback: return .orange
        case .failed: return .red
        case .waiting: return .secondary
        }
    }
}
