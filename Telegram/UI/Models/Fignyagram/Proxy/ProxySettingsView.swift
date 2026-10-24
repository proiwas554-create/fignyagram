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
                    Toggle("Встроенный прокси", isOn: Binding(
                        get: { proxy.isEnabled },
                        set: { proxy.setEnabled($0) }
                    ))
                    HStack {
                        Text("Статус")
                        Spacer()
                        Text(proxy.status)
                            .foregroundColor(statusColor)
                    }
                    HStack {
                        Text("Адрес")
                        Spacer()
                        Text("\(proxy.host):\(proxy.port)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                } footer: {
                    Text("Трафик Telegram идёт с локального адреса 127.0.0.1 через WebSocket-серверы Telegram (wss://kws*.web.telegram.org). Внешний прокси-сервер не используется.")
                        .font(.appFootnote)
                }

                if proxy.health == .directFallback {
                    Section {
                        Text("WebSocket Telegram недоступен, поэтому прокси использует прямое TCP-соединение. Приложение работает, но обход блокировки не выполняется.")
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
                    TextField("Свой Cloudflare-домен (kws*.example.com)", text: $cfProxyDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Сохранить домен и перезапустить") {
                        proxy.restart()
                    }
                } header: {
                    Text("Cloudflare-прокси")
                } footer: {
                    Text("Добавьте в Cloudflare A-записи kws1…kws203 на IP Telegram (SSL/TLS → Flexible). Свой домен обходит блокировку общих CF-доменов.")
                        .font(.appFootnote)
                }

                Section {
                    Button("Перезапустить прокси") {
                        proxy.restart()
                    }
                    .disabled(!proxy.isEnabled)
                } footer: {
                    Text("Прокси работает, пока приложение запущено. После выгрузки приложения из памяти он останавливается, и Telegram снова подключается напрямую.")
                        .font(.appFootnote)
                }

                Section {
                    Text("Внешний MTProto-прокси")
                        .font(.appHeadline)
                    TextField("Сервер, например proxy.example.com", text: $externalServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Порт", text: $externalPort)
                        .keyboardType(.numberPad)
                    TextField("Секрет (hex, можно с dd)", text: $externalSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Подключить внешний прокси") {
                        connectExternal()
                    }
                    .disabled(externalServer.isEmpty || externalSecret.isEmpty)
                    if let externalError {
                        Text(externalError)
                            .font(.appFootnote)
                            .foregroundColor(.red)
                    }
                    Button("Отключить все прокси", role: .destructive) {
                        proxy.setEnabled(false)
                        Task { await TelegramClient.shared.disableAllProxies() }
                    }
                } header: {
                    Text("Аварийный вариант")
                } footer: {
                    Text("Используйте только доверенный прокси: через него проходит весь трафик Telegram. Встроенный прокси при этом отключается.")
                        .font(.appFootnote)
                }

                Section {
                    TextField("Вставьте ключ: vless://, vmess://, trojan://, ss://, tg://proxy…", text: $vpnKeyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Добавить VPN-ключ") {
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
                                Button("Копировать") {
                                    UIPasteboard.general.string = key.raw
                                }
                                if key.mtproto != nil {
                                    Button("Подключить") {
                                        connectVPNKey(key)
                                    }
                                }
                                Button("Удалить", role: .destructive) {
                                    vpnKeys.remove(key)
                                }
                            }
                            .font(.appCaption)
                        }
                    }
                } header: {
                    Text("VPN-ключи")
                } footer: {
                    Text("MTProto-ключи можно сразу подключить как внешний прокси. Ключи VLESS/VMess/Trojan/WireGuard сохраняются для передачи в VPN-клиент: iOS не позволяет стороннему приложению без VPN-расширения поднимать системный туннель.")
                        .font(.appFootnote)
                }

                Section {
                    Text("Реализация основана на tg-ws-proxy (MIT, Flowseal) и его iOS-порте (NeonchikMPT).")
                        .font(.appCaption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Прокси")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
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
