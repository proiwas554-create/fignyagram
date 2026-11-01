import Foundation
import Combine
import Network
import os.log

private let builtInProxyLogger = Logger(subsystem: "com.fignyagram.app", category: "BuiltInProxy")

// Based on the MIT-licensed tg-ws-proxy by Flowseal and its iOS port.
// Owns the local MTProto proxy lifecycle and keeps TDLib's proxy settings in sync.

@MainActor
final class BuiltInProxyManager: ObservableObject {
    static let shared = BuiltInProxyManager()

    private enum Keys {
        static let enabled = "builtInProxyEnabled"
        static let secret = "builtInProxySecret"
    }

    let host = "127.0.0.1"
    let port = 1443

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRunning = false
    @Published private(set) var health: ProxyHealth = .waiting
    @Published private(set) var status = NSLocalizedString("Generated.57165572e062", comment: "")
    @Published private(set) var lastError: String?

    private var server: LocalMTProtoProxy?
    private var operation: Task<Void, Never>?
    private let secret: String
    private let pathMonitor = NWPathMonitor()
    private var wasOffline = false
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var recentUpstreamFailures: [Foundation.Date] = []

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)

        if let stored = Keychain.string(for: Keys.secret), stored.count == 32 {
            secret = stored
        } else if let old = defaults.string(forKey: Keys.secret), old.count == 32 {
            // Migrate the secret from UserDefaults into the Keychain.
            Keychain.set(old, for: Keys.secret)
            defaults.removeObject(forKey: Keys.secret)
            secret = old
        } else {
            let generated = proxySecureRandomBytes(16).map { String(format: "%02x", $0) }.joined()
            Keychain.set(generated, for: Keys.secret)
            secret = generated
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                if !satisfied {
                    self.wasOffline = true
                } else if self.wasOffline {
                    self.wasOffline = false
                    if self.isEnabled {
                        // Never reconnect synchronously from the path
                        // callback: exponential backoff off the main queue.
                        self.scheduleReconnect()
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Fignyagram.ProxyPath"))
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// Called on launch: starts the proxy when it was enabled last time, otherwise
    /// makes sure no stale proxy is enabled in TDLib.
    /// Waits until the local listener is up and the proxy is enabled in TDLib.
    /// Called before the first authorization requests so phone/QR login also
    /// travels through the built-in proxy.
    func ensureActivated() async {
        guard isEnabled else {
            await TelegramClient.shared.deactivateBuiltInProxy(port: port)
            return
        }
        if health == .failed {
            await TelegramClient.shared.deactivateBuiltInProxy(port: port)
            status = NSLocalizedString("Generated.346e9336dea8", comment: "")
            return
        }
        start()
        var attempts = 0
        while !isRunning && attempts < 12 {
            // Stop waiting early when the listener definitively failed.
            if status.hasPrefix("Не удалось") { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        guard isRunning else { return }
        do {
            try await TelegramClient.shared.activateBuiltInProxy(port: port, secret: secret)
        } catch {
            lastError = TelegramClient.describe(error)
        }
    }

    /// A previous build disabled the built-in proxy automatically when the
    /// connection flapped; that turned out to break networking on networks
    /// where the proxy is required. Restore the user's setting once.
    /// One-time rollback of the proxy state that was changed by the removed
    /// watchdog. Direct connection is what worked before the incident.
    /// Restore the configuration that was in use when calls worked: the
    /// built-in proxy running, TDLib routed through it.
    func restoreWorkingProxyOnce() {
        let key = "proxyRestoredWorkingConfig"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled {
            setEnabled(true)
            CallDiag.log("proxy restored to the working configuration")
        }
    }

    func rollbackProxyIncident() {
        let key = "proxyIncidentRollback"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if isEnabled {
            setEnabled(false)
            CallDiag.log("proxy rollback: built-in proxy disabled, using direct connection")
        }
    }

    /// The user originally had the built-in proxy enabled; earlier builds
    /// switched it off automatically. Restore it exactly once and never touch
    /// this setting again.
    func restoreUserProxySettingOnce() {
        let key = "proxyRestoredAfterIncident"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled {
            setEnabled(true)
            CallDiag.log("proxy restored to the user's original enabled state")
        }
    }

    func restoreProxyIfDisabledByMigration() {
        let key = "proxyRestoreMigrationDidRun"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled {
            setEnabled(true)
            CallDiag.log("proxy restored after watchdog migration")
        }
    }

    func applyIfEnabled() {
        if isEnabled {
            start()
        } else {
            Task { await TelegramClient.shared.deactivateBuiltInProxy(port: port) }
        }
    }

    /// Reconnect with exponential backoff: 2s, 4s, 8s … capped at 30s.
    /// Runs entirely off the main queue so XPC/PointerUI services are never
    /// hammered by a reconnect storm.
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        reconnectAttempts += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempts, 6))))
        builtInProxyLogger.info("Proxy reconnect in \(delay)s (attempt \(self.reconnectAttempts))")
        reconnectTask = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.reconnectTask = nil
                self.reconnectAttempts = self.isRunning ? 0 : self.reconnectAttempts
                self.restart()
            }
        }
    }

    func start() {
        DiagnosticsLog.log("proxy.start enabled=\(isEnabled) running=\(isRunning)")
        guard isEnabled, !isRunning, operation == nil else { return }
        reconnectAttempts = 0
        status = NSLocalizedString("Generated.81392999a5d2", comment: "")
        lastError = nil

        var config = ProxyEndpointConfig(port: port, secretHex: secret)
        config.customCFDomain = UserDefaults.standard.string(forKey: "cfProxyDomain")
        operation = Task {
            // Reuse an already listening server instead of binding a second one.
            if let existing = server, existing.isListening {
                do {
                    try await TelegramClient.shared.activateBuiltInProxy(port: port, secret: secret)
                    isRunning = true
                    status = "Работает — \(host):\(port)"
                    lastError = nil
                } catch {
                    await TelegramClient.shared.deactivateBuiltInProxy(port: port)
                    status = NSLocalizedString("Generated.2ffa90882c2a", comment: "")
                    lastError = TelegramClient.describe(error)
                }
                operation = nil
                return
            }

            // Give the previous listener time to release port 1443.
            if let stale = server {
                stale.stop()
                server = nil
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            // Don't block startup on the WebSocket preflight. Telegram's kws*
            // frontends can be temporarily unreachable or the hardcoded IP can
            // be stale; the local proxy itself falls back to direct TCP per DC.
            status = NSLocalizedString("Generated.731c6ed48530", comment: "")

            var startedProxy: LocalMTProtoProxy?
            var lastStartError: Error?
            for attempt in 0..<3 {
                if Task.isCancelled || !isEnabled { break }
                let candidate = LocalMTProtoProxy(config: config)
                candidate.onHealth = { [weak self] health in
                    Task { @MainActor [weak self] in
                        self?.applyHealth(health)
                    }
                }
                do {
                    try await candidate.start()
                    startedProxy = candidate
                    break
                } catch {
                    lastStartError = error
                    candidate.stop()
                    if attempt < 2 {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                    }
                }
            }

            guard let proxy = startedProxy else {
                if !Task.isCancelled {
                    await TelegramClient.shared.deactivateBuiltInProxy(port: port)
                    isRunning = false
                    status = NSLocalizedString("Generated.560c8e8a9a80", comment: "")
                    lastError = TelegramClient.describe(lastStartError ?? ProxyTimeoutError())
                }
                operation = nil
                return
            }

            guard !Task.isCancelled, isEnabled else {
                proxy.stop()
                operation = nil
                return
            }

            do {
                try await TelegramClient.shared.activateBuiltInProxy(port: port, secret: secret)
            } catch {
                proxy.stop()
                await TelegramClient.shared.deactivateBuiltInProxy(port: port)
                isRunning = false
                status = NSLocalizedString("Generated.2ffa90882c2a", comment: "")
                lastError = TelegramClient.describe(error)
                operation = nil
                return
            }

            guard !Task.isCancelled, isEnabled else {
                await TelegramClient.shared.deactivateBuiltInProxy(port: port)
                proxy.stop()
                operation = nil
                return
            }

            server = proxy
            isRunning = true
            status = NSLocalizedString("Generated.f29aa48606b4", comment: "")
            DiagnosticsLog.log("proxy.running port=\(port)")
            lastError = nil
            operation = nil
            startHealthTimeout()
        }
    }

    private var healthTimeoutTask: Task<Void, Never>?

    private func startHealthTimeout() {
        healthTimeoutTask?.cancel()
        healthTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.isRunning, self.status.hasPrefix("Ожидание") {
                self.health = .failed
                self.status = NSLocalizedString("Generated.7aef029a9610", comment: "")
                self.lastError = NSLocalizedString("Generated.a56145585e65", comment: "")
            }
        }
    }

    private func applyHealth(_ health: ProxyHealth) {
        guard isRunning else { return }
        healthTimeoutTask?.cancel()
        self.health = health
        switch health {
        case .waiting:
            status = NSLocalizedString("Generated.f29aa48606b4", comment: "")
        case .webSocket:
            status = NSLocalizedString("Generated.742861a9adcc", comment: "")
            lastError = nil
        case .cloudflare:
            status = NSLocalizedString("Generated.c729291c230a", comment: "")
            lastError = nil
        case .directFallback:
            status = NSLocalizedString("Generated.0de32731cc10", comment: "")
            lastError = nil
        case .failed:
            status = NSLocalizedString("Generated.7aef029a9610", comment: "")
            lastError = NSLocalizedString("Generated.a56145585e65", comment: "")
            registerUpstreamFailure()
        }
    }

    /// Called when the app returns to the foreground: iOS may have torn down
    /// the listening socket while the app was suspended.
    func refreshOnActivation() {
        guard isEnabled, isRunning, operation == nil else { return }
        if server?.isListening != true {
            restart()
        }
    }

    /// Hard kill-switch: more than 3 upstream failures in 5 seconds stops the
    /// proxy instead of burning ports and tripping iOS NECP/XPC limits.
    private func registerUpstreamFailure() {
        let now = Foundation.Date()
        recentUpstreamFailures = recentUpstreamFailures.filter { now.timeIntervalSince($0) < 5 }
        recentUpstreamFailures.append(now)
        guard recentUpstreamFailures.count >= 3 else { return }
        recentUpstreamFailures.removeAll()
        builtInProxyLogger.critical("Proxy storm-stop: 3+ failures in 5s")
        stop()
        status = NSLocalizedString("Generated.5670c8be31aa", comment: "")
        lastError = NSLocalizedString("Generated.792cd2589be4", comment: "")
    }

    func stop() {
        operation?.cancel()
        operation = nil
        healthTimeoutTask?.cancel()
        healthTimeoutTask = nil

        let proxy = server
        server = nil
        isRunning = false
        status = NSLocalizedString("Generated.7cc8aa092322", comment: "")

        Task {
            await TelegramClient.shared.deactivateBuiltInProxy(port: port)
            proxy?.stop()
            status = NSLocalizedString("Generated.57165572e062", comment: "")
        }
    }

    func restart() {
        operation?.cancel()
        operation = nil

        let proxy = server
        server = nil
        isRunning = false
        status = NSLocalizedString("Generated.99e0a8e31f71", comment: "")

        Task {
            await TelegramClient.shared.deactivateBuiltInProxy(port: port)
            proxy?.stop()
            // Let the listening socket fully close before rebinding the same port.
            try? await Task.sleep(nanoseconds: 350_000_000)
            start()
        }
    }
}
