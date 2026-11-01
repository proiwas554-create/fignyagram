import Foundation
import Network
import os.log

// Based on the MIT-licensed tg-ws-proxy by Flowseal and its iOS port.
// Runs a local MTProto proxy (obfuscated2) and bridges it to Telegram over WebSocket.

private let proxyServerLogger = Logger(subsystem: "com.fignyagram.app", category: "LocalMTProtoProxy")

nonisolated let proxyHandshakeLength = 64
nonisolated let proxySkipLength = 8
nonisolated let proxyPrekeyLength = 32
nonisolated let proxyKeyLength = 32
nonisolated let proxyIVLength = 16
nonisolated let proxyProtoTagPosition = 56
nonisolated let proxyDcIndexPosition = 60

nonisolated let proxyProtoTagAbridged: [UInt8] = [0xEF, 0xEF, 0xEF, 0xEF]
nonisolated let proxyProtoTagIntermediate: [UInt8] = [0xEE, 0xEE, 0xEE, 0xEE]
nonisolated let proxyProtoTagSecure: [UInt8] = [0xDD, 0xDD, 0xDD, 0xDD]

nonisolated let proxyProtoAbridged: UInt32 = 0xEFEFEFEF
nonisolated let proxyProtoIntermediate: UInt32 = 0xEEEEEEEE
nonisolated let proxyProtoPaddedIntermediate: UInt32 = 0xDDDDDDDD

nonisolated let proxyReservedFirstBytes: Set<UInt8> = [0xEF]
nonisolated let proxyReservedStarts: Set<[UInt8]> = [
    [0x48, 0x45, 0x41, 0x44],  // HEAD
    [0x50, 0x4F, 0x53, 0x54],  // POST
    [0x47, 0x45, 0x54, 0x20],  // GET
    [0xEE, 0xEE, 0xEE, 0xEE],
    [0xDD, 0xDD, 0xDD, 0xDD],
    [0x16, 0x03, 0x01, 0x02],
]
nonisolated let proxyReservedContinue: [UInt8] = [0x00, 0x00, 0x00, 0x00]
nonisolated let proxyZero64 = [UInt8](repeating: 0, count: 64)

nonisolated struct ProxyHandshakeResult {
    let dcId: Int
    let isMedia: Bool
    let protoTag: [UInt8]
    let protoInt: UInt32
    let clientDecPrekeyIV: [UInt8]
}

nonisolated func proxyTryHandshake(_ handshake: [UInt8], secret: [UInt8]) -> ProxyHandshakeResult? {
    guard handshake.count == proxyHandshakeLength else { return nil }

    let decPrekeyAndIV = Array(handshake[proxySkipLength ..< proxySkipLength + proxyPrekeyLength + proxyIVLength])
    let decPrekey = Array(decPrekeyAndIV[0..<proxyPrekeyLength])
    let decIV = Array(decPrekeyAndIV[proxyPrekeyLength...])

    let decKey = proxySHA256(decPrekey + secret)
    let decryptor = ProxyAESCTR(key: decKey, iv: decIV)
    let decrypted = decryptor.process(handshake)

    let protoTag = Array(decrypted[proxyProtoTagPosition ..< proxyProtoTagPosition + 4])
    guard protoTag == proxyProtoTagAbridged ||
          protoTag == proxyProtoTagIntermediate ||
          protoTag == proxyProtoTagSecure else {
        return nil
    }

    let rawDCIndex = UInt16(decrypted[proxyDcIndexPosition]) |
                     (UInt16(decrypted[proxyDcIndexPosition + 1]) << 8)
    let dcIdx = Int(Int16(bitPattern: rawDCIndex))
    let dcId = abs(dcIdx)
    let isMedia = dcIdx < 0

    let protoInt: UInt32
    if protoTag == proxyProtoTagAbridged {
        protoInt = proxyProtoAbridged
    } else if protoTag == proxyProtoTagIntermediate {
        protoInt = proxyProtoIntermediate
    } else {
        protoInt = proxyProtoPaddedIntermediate
    }

    return ProxyHandshakeResult(
        dcId: dcId,
        isMedia: isMedia,
        protoTag: protoTag,
        protoInt: protoInt,
        clientDecPrekeyIV: decPrekeyAndIV
    )
}

nonisolated func proxyMakeRelayInit(protoTag: [UInt8], dcIdx: Int) -> [UInt8] {
    // Безопасный генератор: не больше 64 итераций и ни одной бесконечной
    // петли, если SecRandom вернёт нули (страховка от 0 FPS-зависаний).
    for _ in 0..<64 {
        let random = proxySecureRandomBytes(proxyHandshakeLength)

        if proxyReservedFirstBytes.contains(random[0]) { continue }
        if proxyReservedStarts.contains(Array(random[0..<4])) { continue }
        if Array(random[4..<8]) == proxyReservedContinue { continue }

        let encKey = Array(random[proxySkipLength ..< proxySkipLength + proxyPrekeyLength])
        let encIV = Array(random[proxySkipLength + proxyPrekeyLength ..< proxySkipLength + proxyPrekeyLength + proxyIVLength])

        let encryptor = ProxyAESCTR(key: encKey, iv: encIV)

        let dcBytes: [UInt8] = withUnsafeBytes(of: Int16(dcIdx).littleEndian) { Array($0) }
        let tailPlain = protoTag + dcBytes + proxySecureRandomBytes(2)

        let encryptedFull = encryptor.process(random)
        var keystreamTail = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            keystreamTail[i] = encryptedFull[56 + i] ^ random[56 + i]
        }

        var encryptedTail = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            encryptedTail[i] = tailPlain[i] ^ keystreamTail[i]
        }

        var result = random
        result[proxyProtoTagPosition..<proxyHandshakeLength] = ArraySlice(encryptedTail)
        return result
    }

    // Fallback (64 коллизий подряд практически невозможны): возвращаем
    // заведомо валидный фиксированный заголовок, чтобы вызов гарантированно
    // завершался.
    var fallback = [UInt8](repeating: 0xEF, count: proxyHandshakeLength)
    fallback[proxyProtoTagPosition..<proxyProtoTagPosition + 4] = ArraySlice(protoTag)
    return fallback
}

nonisolated func proxyWebSocketDomains(dc: Int, isMedia: Bool, overrides: [Int: Int]) -> [String] {
    let effectiveDC = overrides[dc] ?? dc
    if isMedia {
        return ["kws\(effectiveDC)-1.web.telegram.org", "kws\(effectiveDC).web.telegram.org"]
    }
    return ["kws\(effectiveDC).web.telegram.org", "kws\(effectiveDC)-1.web.telegram.org"]
}

/// Splits the client's byte stream into MTProto packets so every WebSocket
/// message contains exactly one packet.
nonisolated final class ProxyMessageSplitter {
    private var decryptor: ProxyAESCTR
    private let proto: UInt32
    private var cipherBuffer = Data()
    private var plainBuffer = Data()
    private var disabled = false

    init(relayInit: [UInt8], protoInt: UInt32) {
        let key = Array(relayInit[8..<40])
        let iv = Array(relayInit[40..<56])
        decryptor = ProxyAESCTR(key: key, iv: iv)
        _ = decryptor.process(proxyZero64)
        proto = protoInt
    }

    func split(_ chunk: Data) -> [Data] {
        if chunk.isEmpty { return [] }
        if disabled { return [chunk] }

        cipherBuffer.append(chunk)
        plainBuffer.append(Data(decryptor.process([UInt8](chunk))))

        var parts: [Data] = []
        while !cipherBuffer.isEmpty {
            guard let packetLength = nextPacketLength() else { break }
            if packetLength <= 0 {
                parts.append(Data(cipherBuffer))
                cipherBuffer.removeAll()
                plainBuffer.removeAll()
                disabled = true
                break
            }
            // Data slices keep a non-zero startIndex; normalise before handing
            // them to the WebSocket framer.
            parts.append(Data(cipherBuffer.prefix(packetLength)))
            cipherBuffer.removeFirst(packetLength)
            plainBuffer.removeFirst(packetLength)
        }
        return parts
    }

    func flush() -> [Data] {
        guard !cipherBuffer.isEmpty else { return [] }
        let tail = Data(cipherBuffer)
        cipherBuffer.removeAll()
        plainBuffer.removeAll()
        return [tail]
    }

    private func nextPacketLength() -> Int? {
        if plainBuffer.isEmpty { return nil }
        if proto == proxyProtoAbridged {
            return nextAbridgedLength()
        }
        if proto == proxyProtoIntermediate || proto == proxyProtoPaddedIntermediate {
            return nextIntermediateLength()
        }
        return 0
    }

    private func nextAbridgedLength() -> Int? {
        let first = plainBuffer[plainBuffer.startIndex]
        let payloadLength: Int
        let headerLength: Int
        if first == 0x7F || first == 0xFF {
            if plainBuffer.count < 4 { return nil }
            payloadLength = (Int(plainBuffer[plainBuffer.startIndex + 1]) |
                             (Int(plainBuffer[plainBuffer.startIndex + 2]) << 8) |
                             (Int(plainBuffer[plainBuffer.startIndex + 3]) << 16)) * 4
            headerLength = 4
        } else {
            payloadLength = Int(first & 0x7F) * 4
            headerLength = 1
        }
        if payloadLength <= 0 { return 0 }
        let packetLength = headerLength + payloadLength
        if plainBuffer.count < packetLength { return nil }
        return packetLength
    }

    private func nextIntermediateLength() -> Int? {
        if plainBuffer.count < 4 { return nil }
        // Data isn't guaranteed to be 4-byte aligned, so read the little-endian
        // length byte by byte instead of load(as: UInt32.self).
        let start = plainBuffer.startIndex
        let raw = UInt32(plainBuffer[start])
            | UInt32(plainBuffer[start + 1]) << 8
            | UInt32(plainBuffer[start + 2]) << 16
            | UInt32(plainBuffer[start + 3]) << 24
        let payloadLength = Int(raw & 0x7FFFFFFF)
        if payloadLength <= 0 { return 0 }
        let packetLength = 4 + payloadLength
        if plainBuffer.count < packetLength { return nil }
        return packetLength
    }
}

nonisolated struct ProxyEndpointConfig {
    var port: Int
    var secretHex: String
    var dcRedirects: [Int: String] = [
        1: "149.154.175.50",
        2: "149.154.167.51",
        3: "149.154.175.100",
        4: "149.154.167.91",
        5: "149.154.171.5",
        203: "91.105.192.100"
    ]
    var dcOverrides: [Int: Int] = [203: 2]
    /// CF-proxy domains from the tg-ws-proxy project. They point at
    /// Cloudflare-proxied kws{N}.<domain> records, so traffic does not go
    /// directly to Telegram's blocked IP ranges.
    /// User-supplied Cloudflare domain (kws1…kws203 A-records, see
    /// tg-ws-proxy docs). When set, it is tried first; bundled domains remain
    /// as fallback.
    var customCFDomain: String?
    var cfDomains: [String] = [
        "cakeisalie.co.uk",
        "noskomnadzor.co.uk",
        "offshor.co.uk",
        "lovetrue.co.uk",
        "pclead.co.uk"
    ]

    var effectiveCFDomains: [String] {
        if let custom = customCFDomain?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return [custom] + cfDomains.filter { $0 != custom }
        }
        return cfDomains
    }

    static let dcDefaultIPs: [Int: String] = [
        1: "149.154.175.50",
        2: "149.154.167.51",
        3: "149.154.175.100",
        4: "149.154.167.91",
        5: "149.154.171.5",
        203: "91.105.192.100"
    ]
}

/// Local MTProto proxy that forwards Telegram traffic through
/// wss://kwsN.web.telegram.org. TDLib connects to it via 127.0.0.1;
/// the random MTProto secret prevents unauthorized use.
nonisolated enum ProxyHealth: Sendable {
    case waiting
    case webSocket
    case cloudflare
    case directFallback
    case failed
}

nonisolated final class LocalMTProtoProxy: @unchecked Sendable {
    private let config: ProxyEndpointConfig
    /// Reports the actual upstream transport of the last Telegram connection.
    var onHealth: (@Sendable (ProxyHealth) -> Void)?
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var ready = false
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionQueues: [ObjectIdentifier: DispatchQueue] = [:]

    private func queue(for connection: NWConnection) -> DispatchQueue {
        let key = ObjectIdentifier(connection)
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = connectionQueues[key] { return existing }
        let created = DispatchQueue(label: "Fignyagram.proxy.conn.\(connectionQueues.count)")
        connectionQueues[key] = created
        return created
    }
    /// Per-DC upstream failure bookkeeping: (consecutive failures, retryAfter).
    private var dcFailures: [Int: (count: Int, retryAfter: Foundation.Date)] = [:]
    /// Global accept cooldown: while active, new TDLib connections are rejected
    /// immediately so iOS stops allocating a fresh local port every millisecond.
    private var acceptCooldownUntil: Foundation.Date = .distantPast
    /// DCs where Cloudflare answers 101 and then closes instantly. After two
    /// such failures the DC goes straight to direct WS/TCP.
    private var cfBrokenDCs: Set<Int> = []
    enum UpstreamKind { case cf, direct, tcp }
    /// Transport that worked last time for a DC: skip dead alternatives and
    /// connect faster on the next request (media loads, reconnect, login).
    private var preferredTransport: [Int: UpstreamKind] = [:]
    private var cfInstantCloses: [Int: Int] = [:]
    /// Session-wide kill for Cloudflare: a -1011 (HTTP rejection instead of a
    /// WebSocket upgrade) means the CF frontends are dead, not that the network
    /// is down. Stop touching them until the proxy restarts.
    private var cfDeadForSession = false

    init(config: ProxyEndpointConfig) {
        self.config = config
    }

    /// Checks that Telegram's WebSocket endpoints are reachable before TDLib is
    /// pointed at the local proxy. If they are blocked, the app keeps working directly.
    static func preflight() async throws {
        let domains = ["kws2.web.telegram.org", "kws4.web.telegram.org"]
        // Telegram occasionally rotates the WebSocket frontends; DNS is the
        // primary source of truth, with a few known IPs as fallback.
        let fallbackIPs = [
            "149.154.167.220",
            "149.154.167.51",
            "149.154.175.100",
            "91.108.56.130"
        ]

        var lastError: Error = ProxyTimeoutError()
        for domain in domains {
            do {
                let socket = try await ProxyWebSocket.connect(domain: domain, timeout: 20)
                await socket.close()
                proxyServerLogger.info("Proxy preflight OK via DNS \(domain)")
                return
            } catch {
                lastError = error
                proxyServerLogger.warning("Proxy preflight DNS failed via \(domain): \(String(describing: error))")
            }

            for ip in fallbackIPs {
                do {
                    let socket = try await ProxyWebSocket.connect(ip: ip, domain: domain, timeout: 20)
                    await socket.close()
                    proxyServerLogger.info("Proxy preflight OK via \(domain) / \(ip)")
                    return
                } catch {
                    lastError = error
                    proxyServerLogger.warning("Proxy preflight failed \(domain) / \(ip): \(String(describing: error))")
                }
            }
        }
        throw ProxyTimeoutError(underlying: lastError)
    }

    func start() async throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        // Loopback server for TDLib: explicitly allow local endpoint reuse and
        // peer-to-peer so the OS never applies carrier/joining-protocol
        // policies to 127.0.0.1 traffic.
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        guard let port = NWEndpoint.Port(rawValue: UInt16(config.port)) else {
            throw NWError.posix(.EINVAL)
        }
        let listener = try NWListener(using: params, on: port)
        setListener(listener)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task {
                await self.handleNewConnection(connection)
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ProxyOnceFlag()
            let timer = DispatchWorkItem {
                if once.trySet() {
                    listener.cancel()
                    cont.resume(throwing: ProxyTimeoutError())
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10, execute: timer)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.trySet() else { return }
                    timer.cancel()
                    listener.stateUpdateHandler = nil
                    self?.setReady(true)
                    proxyServerLogger.info("Local proxy listening on port \(self?.config.port ?? 0)")
                    cont.resume()
                case .failed(let error):
                    guard once.trySet() else { return }
                    timer.cancel()
                    listener.stateUpdateHandler = nil
                    self?.setReady(false)
                    cont.resume(throwing: error)
                case .cancelled:
                    guard once.trySet() else { return }
                    timer.cancel()
                    listener.stateUpdateHandler = nil
                    self?.setReady(false)
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    var isListening: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ready
    }

    private func report(_ health: ProxyHealth) {
        onHealth?(health)
    }

    private func setReady(_ value: Bool) {
        stateLock.lock()
        ready = value
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        ready = false
        let listener = self.listener
        self.listener = nil
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        stateLock.unlock()

        listener?.cancel()
        for connection in connections {
            connection.cancel()
        }
    }

    // MARK: - Connections

    private func setListener(_ listener: NWListener?) {
        stateLock.lock()
        self.listener = listener
        stateLock.unlock()
    }

    @discardableResult
    private func track(_ connection: NWConnection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeConnections.count < 64 else { return false }
        activeConnections[ObjectIdentifier(connection)] = connection
        return true
    }

    private func untrack(_ connection: NWConnection) {
        stateLock.lock()
        activeConnections[ObjectIdentifier(connection)] = nil
        stateLock.unlock()
        // Full teardown before the OS reuses the slot: clear the state handler
        // first, then cancel — never leave a handler on a dead socket.
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func handleNewConnection(_ connection: NWConnection) async {
        // Low-level gate: during the backoff window drop the connection BEFORE
        // any handler registration. TDLib sees an immediate reset (equivalent
        // of ECONNREFUSED) and paces its own retries — the port churn stops.
        if !SocketGate.shared.tryEnter() || acceptCooldownRemaining() != nil {
            connection.cancel()
            return
        }
        guard track(connection) else {
            proxyServerLogger.warning("Too many proxy connections, rejecting a new one")
            connection.cancel()
            return
        }
        let connectionQueue = queue(for: connection)
        connection.start(queue: connectionQueue)

        do {
            try await processClient(connection)
        } catch {
            proxyServerLogger.debug("Client connection error: \(String(describing: error))")
        }

        untrack(connection)
        connection.cancel()
    }

    private func processClient(_ connection: NWConnection) async throws {
        try await waitForReady(connection)

        let handshakeData = try await receiveExact(connection, count: proxyHandshakeLength)
        let handshake = [UInt8](handshakeData)
        let secretBytes = proxyHexToBytes(config.secretHex)

        guard secretBytes.count == 16, let result = proxyTryHandshake(handshake, secret: secretBytes) else {
            proxyServerLogger.debug("Bad handshake (wrong secret or proto)")
            _ = try? await receiveData(connection, maxLength: 4096, timeout: 20)
            return
        }

        let dcIdx = result.isMedia ? -result.dcId : result.dcId
        let relayInit = proxyMakeRelayInit(protoTag: result.protoTag, dcIdx: dcIdx)

        let clientDecPrekey = Array(result.clientDecPrekeyIV[0..<proxyPrekeyLength])
        let clientDecIV = Array(result.clientDecPrekeyIV[proxyPrekeyLength...])
        let clientDecKey = proxySHA256(clientDecPrekey + secretBytes)

        let clientEncPrekeyIV = Array(result.clientDecPrekeyIV.reversed())
        let clientEncKey = proxySHA256(Array(clientEncPrekeyIV[0..<proxyPrekeyLength]) + secretBytes)
        let clientEncIV = Array(clientEncPrekeyIV[proxyPrekeyLength...])

        let clientDecryptor = ProxyAESCTR(key: clientDecKey, iv: clientDecIV)
        let clientEncryptor = ProxyAESCTR(key: clientEncKey, iv: clientEncIV)
        _ = clientDecryptor.process(proxyZero64)

        let relayEncKey = Array(relayInit[proxySkipLength ..< proxySkipLength + proxyPrekeyLength])
        let relayEncIV = Array(relayInit[proxySkipLength + proxyPrekeyLength ..< proxySkipLength + proxyPrekeyLength + proxyIVLength])

        let relayDecPrekeyIV = Array(relayInit[proxySkipLength ..< proxySkipLength + proxyPrekeyLength + proxyIVLength].reversed())
        let relayDecKey = Array(relayDecPrekeyIV[0..<proxyKeyLength])
        let relayDecIV = Array(relayDecPrekeyIV[proxyKeyLength...])

        let telegramEncryptor = ProxyAESCTR(key: relayEncKey, iv: relayEncIV)
        let telegramDecryptor = ProxyAESCTR(key: relayDecKey, iv: relayDecIV)
        _ = telegramEncryptor.process(proxyZero64)

        let mediaTag = result.isMedia ? "m" : ""
        proxyServerLogger.info("Handshake ok: DC\(result.dcId)\(mediaTag)")

        // Reconnect storm gate: after a failed upstream dial the same DC must
        // wait 2s → 4s → 8s … before the next dial. TDLib keeps opening local
        // TCP connections, but the proxy no longer dials upstream for each one,
        // so the OS is not flooded with sockets/ports.
        if let gateDelay = upstreamGateDelay(for: result.dcId) {
            proxyServerLogger.info("DC\(result.dcId) gate: waiting \(gateDelay)s before dial")
            try? await Task.sleep(nanoseconds: UInt64(gateDelay * 1_000_000_000))
            if isDead(connection) {
                throw ProxyWebSocket.ConnectionError.closed
            }
        }

        // One of at most two concurrent dials: the UI keeps its frames even
        // while TDLib opens several connections at once.
        return try await ProxyDialLimiter.shared.withSlot {
        // Never let a dead CF/DC endpoint block authorization for minutes.
        let connectDeadline = Date().addingTimeInterval(5)
        let preferTCP: Bool = {
            stateLock.lock(); defer { stateLock.unlock() }
            return preferredTransport[result.dcId] == .tcp
        }()
        if preferTCP {
            let fallbackIP = config.dcRedirects[result.dcId]
                ?? ProxyEndpointConfig.dcDefaultIPs[result.dcId]
                ?? "149.154.167.51"
            recordUpstreamFailure(dcId: result.dcId)
            return try await tcpFallback(
                connection: connection, destination: fallbackIP, port: 443,
                relayInit: relayInit,
                clientDecryptor: clientDecryptor, clientEncryptor: clientEncryptor,
                telegramEncryptor: telegramEncryptor, telegramDecryptor: telegramDecryptor
            )
        }

        guard let targetIP = config.dcRedirects[result.dcId] else {
            if let fallbackIP = ProxyEndpointConfig.dcDefaultIPs[result.dcId] {
                proxyServerLogger.info("DC\(result.dcId) is not redirected, TCP fallback to \(fallbackIP):443")
                try await tcpFallback(
                    connection: connection, destination: fallbackIP, port: 443,
                    relayInit: relayInit,
                    clientDecryptor: clientDecryptor, clientEncryptor: clientEncryptor,
                    telegramEncryptor: telegramEncryptor, telegramDecryptor: telegramDecryptor
                )
            }
            return
        }

        let domains = proxyWebSocketDomains(dc: result.dcId, isMedia: result.isMedia, overrides: config.dcOverrides)

        var websocket: ProxyWebSocket?
        var ipCandidates = [targetIP]
        if let dcIP = ProxyEndpointConfig.dcDefaultIPs[result.dcId], !ipCandidates.contains(dcIP) {
            ipCandidates.append(dcIP)
        }
        for extra in ["149.154.167.220", "149.154.167.99"] where !ipCandidates.contains(extra) {
            ipCandidates.append(extra)
        }

        // Cloudflare first: its edge is usually reachable when Telegram IPs
        // are blocked by the ISP.
        let cfAllowed: Bool = {
            stateLock.lock()
            defer { stateLock.unlock() }
            if let preferred = preferredTransport[result.dcId] { return preferred == .cf }
            return !cfDeadForSession && !cfBrokenDCs.contains(result.dcId)
        }()
        let cfDomains = config.effectiveCFDomains
        if cfDomains.isEmpty == false && cfAllowed {
            for cfDomain in cfDomains.prefix(2) {
                if Date() >= connectDeadline { break }
                let host = "kws\(result.dcId).\(cfDomain)"
                proxyServerLogger.info("DC\(result.dcId)\(mediaTag) -> wss://\(host)/apiws (CF proxy)")
                do {
                    websocket = try await ProxyWebSocket.connect(domain: host, timeout: 2.5)
                    proxyServerLogger.info("WS connected via CF: \(host)")
                    report(.cloudflare)
                    stateLock.lock(); preferredTransport[result.dcId] = .cf; stateLock.unlock()
                    break
                } catch let error as URLError where error.code == .badServerResponse {
                    // HTTP-отказ вместо апгрейда: CF-домен мёртв. Больше не
                    // трогаем Cloudflare до перезапуска прокси и идём в TCP.
                    proxyServerLogger.warning("DC\(result.dcId) CF \(host) rejected handshake (-1011), CF disabled for session")
                    stateLock.lock()
                    cfDeadForSession = true
                    stateLock.unlock()
                    break
                } catch {
                    proxyServerLogger.warning("DC\(result.dcId) CF \(host) failed: \(String(describing: error))")
                }
            }
        }

        if websocket == nil, let domain = domains.first {
            // Один DNS-диал и сразу TCP fallback: перебор IP и порта 80
            // через URLSession бессмыслен, когда сеть блокирует WS целиком.
            if Date() < connectDeadline {
                proxyServerLogger.info("DC\(result.dcId)\(mediaTag) -> wss://\(domain)/apiws")
                do {
                    websocket = try await ProxyWebSocket.connect(domain: domain, timeout: 2.0)
                    proxyServerLogger.info("WS connected via DNS: \(domain)")
                    report(.webSocket)
                    stateLock.lock(); preferredTransport[result.dcId] = .direct; stateLock.unlock()
                } catch {
                    proxyServerLogger.warning("DC\(result.dcId) DNS \(domain) failed: \(String(describing: error))")
                }
            }
        }

        guard let websocket else {
            let fallbackIP = ProxyEndpointConfig.dcDefaultIPs[result.dcId] ?? targetIP
            proxyServerLogger.info("DC\(result.dcId)\(mediaTag) WS failed, TCP fallback to \(fallbackIP):443")
            recordUpstreamFailure(dcId: result.dcId)
            stateLock.lock(); preferredTransport[result.dcId] = .tcp; stateLock.unlock()
            try await tcpFallback(
                connection: connection, destination: fallbackIP, port: 443,
                relayInit: relayInit,
                clientDecryptor: clientDecryptor, clientEncryptor: clientEncryptor,
                telegramEncryptor: telegramEncryptor, telegramDecryptor: telegramDecryptor
            )
            return
        }

        let splitter = ProxyMessageSplitter(relayInit: relayInit, protoInt: result.protoInt)

        // send(relayInit) часто падает ЗДЕСЬ (CF закрывает сразу после 101),
        // поэтому и отправка, и бридж живут в одном защищённом блоке: любой
        // мгновенный обрыв попадает в backoff и CF-blacklist.
        let bridgeStart = Foundation.Date()
        do {
            try await websocket.send(Data(relayInit))
            try await bridgeWebSocket(
                connection: connection, websocket: websocket,
                clientDecryptor: clientDecryptor, clientEncryptor: clientEncryptor,
                telegramEncryptor: telegramEncryptor, telegramDecryptor: telegramDecryptor,
                splitter: splitter
            )
            // Бридж прожил заметное время — нормальное завершение, сброс.
            clearUpstreamFailure(dcId: result.dcId)
        } catch {
            let alive = Foundation.Date().timeIntervalSince(bridgeStart)
            if alive < 2 {
                recordUpstreamFailure(dcId: result.dcId)
                proxyServerLogger.info("DC\(result.dcId) upstream closed after \(alive)s — backoff")
                recordCfInstantClose(dcId: result.dcId)
            }
            throw error
        }
        }
    }

    // MARK: - Bridges

    private func bridgeWebSocket(
        connection: NWConnection, websocket: ProxyWebSocket,
        clientDecryptor: ProxyAESCTR, clientEncryptor: ProxyAESCTR,
        telegramEncryptor: ProxyAESCTR, telegramDecryptor: ProxyAESCTR,
        splitter: ProxyMessageSplitter
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                var sentSinceYield = 0
                do {
                    while true {
                        let chunk = try await self.receiveData(connection, maxLength: 65536)
                        guard !chunk.isEmpty else { break }

                        let plain = clientDecryptor.process(chunk)
                        let encrypted = telegramEncryptor.process(plain)
                        let parts = splitter.split(encrypted)
                        if parts.isEmpty { continue }

                        if parts.count > 1 {
                            try await websocket.sendBatch(parts)
                        } else if let part = parts.first {
                            try await websocket.send(part)
                        }
                        // Rate limiter: не выливаем лавину кадров в Cloudflare.
                        sentSinceYield += max(1, parts.count)
                        if sentSinceYield >= 5 {
                            sentSinceYield = 0
                            await Task.yield()
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                    }
                } catch {}
                await websocket.close()
            }

            group.addTask { [weak self] in
                guard let self else { return }
                do {
                    while true {
                        guard let data = try await websocket.recv() else { break }
                        let plain = telegramDecryptor.process(data)
                        let encrypted = clientEncryptor.process(plain)
                        try await self.sendData(connection, data: encrypted)
                    }
                } catch {}
                connection.cancel()
            }

            // Keepalive: Cloudflare drops idle sessions, which reads as an
            // instant "closed" right after a successful dial.
            group.addTask { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled else { break }
                    do { try await websocket.ping() } catch { break }
                }
            }

            do {
                try await group.next()
            } catch {}
            // Closing both sides resumes the peer task even if it is blocked in receive.
            connection.cancel()
            await websocket.close()
            group.cancelAll()
        }
    }

    private func tcpFallback(
        connection: NWConnection, destination: String, port: Int,
        relayInit: [UInt8],
        clientDecryptor: ProxyAESCTR, clientEncryptor: ProxyAESCTR,
        telegramEncryptor: ProxyAESCTR, telegramDecryptor: ProxyAESCTR
    ) async throws {
        var lastError: Error = ProxyTimeoutError()
        var ports = [port]
        for candidate in [80, 5222] where !ports.contains(candidate) {
            ports.append(candidate)
        }
        for candidate in ports {
            do {
                try await tcpFallbackOnce(
                    connection: connection, destination: destination, port: candidate,
                    relayInit: relayInit,
                    clientDecryptor: clientDecryptor, clientEncryptor: clientEncryptor,
                    telegramEncryptor: telegramEncryptor, telegramDecryptor: telegramDecryptor
                )
                return
            } catch {
                lastError = error
                proxyServerLogger.warning("TCP fallback \(destination):\(candidate) failed: \(String(describing: error))")
            }
        }
        report(.failed)
        throw lastError
    }

    private func tcpFallbackOnce(
        connection: NWConnection, destination: String, port: Int,
        relayInit: [UInt8],
        clientDecryptor: ProxyAESCTR, clientEncryptor: ProxyAESCTR,
        telegramEncryptor: ProxyAESCTR, telegramDecryptor: ProxyAESCTR
    ) async throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true

        guard let remotePort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(destination), port: remotePort)
        let remote = NWConnection(to: endpoint, using: params)
        remote.start(queue: queue(for: remote))

        do {
            try await waitForReady(remote, timeout: 4)
            try await sendData(remote, data: Data(relayInit))
            report(.directFallback)
            clearUpstreamFailure(dcId: dcIdForFallback(destination))
        } catch {
            remote.cancel()
            throw error
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                do {
                    while true {
                        let data = try await self.receiveData(connection, maxLength: 65536)
                        guard !data.isEmpty else { break }
                        let plain = clientDecryptor.process(data)
                        let encrypted = telegramEncryptor.process(plain)
                        try await self.sendData(remote, data: encrypted)
                    }
                } catch {}
                remote.cancel()
            }

            group.addTask { [weak self] in
                guard let self else { return }
                do {
                    while true {
                        let data = try await self.receiveData(remote, maxLength: 65536)
                        guard !data.isEmpty else { break }
                        let plain = telegramDecryptor.process(data)
                        let encrypted = clientEncryptor.process(plain)
                        try await self.sendData(connection, data: encrypted)
                    }
                } catch {}
                connection.cancel()
            }

            do {
                try await group.next()
            } catch {}
            connection.cancel()
            remote.cancel()
            group.cancelAll()
        }
    }

    // MARK: - NWConnection helpers

    // MARK: - Upstream reconnect gate

    private func upstreamGateDelay(for dcId: Int) -> TimeInterval? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let entry = dcFailures[dcId] else { return nil }
        let remaining = entry.retryAfter.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    private func recordUpstreamFailure(dcId: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let count = (dcFailures[dcId]?.count ?? 0) + 1
        // 1s → 2s → 4s … + случайный сдвиг 0…1s: несколько клиентов/DC не
        // бьют Cloudflare в одну и ту же миллисекунду.
        let delay = min(30.0, 1.0 * pow(2.0, Double(min(count, 6)))) + Double.random(in: 0.0...1.0)
        dcFailures[dcId] = (count, Foundation.Date().addingTimeInterval(delay))
        // The same window gates the listener: reject new local connections
        // while the upstream recovers.
        acceptCooldownUntil = Foundation.Date().addingTimeInterval(delay)
        SocketGate.shared.recordFailure()
    }

    private func clearUpstreamFailure(dcId: Int) {
        stateLock.lock()
        dcFailures[dcId] = nil
        acceptCooldownUntil = .distantPast
        stateLock.unlock()
        SocketGate.shared.recordSuccess()
    }

    private func recordCfInstantClose(dcId: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let count = (cfInstantCloses[dcId] ?? 0) + 1
        cfInstantCloses[dcId] = count
        if count >= 2 {
            cfBrokenDCs.insert(dcId)
            proxyServerLogger.info("DC\(dcId): Cloudflare unstable, switching to direct WS/TCP")
        }
    }

    private func acceptCooldownRemaining() -> TimeInterval? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let remaining = acceptCooldownUntil.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    private func dcIdForFallback(_ destination: String) -> Int {
        ProxyEndpointConfig.dcDefaultIPs.first(where: { $0.value == destination })?.key ?? 0
    }

    private func isDead(_ connection: NWConnection) -> Bool {
        switch connection.state {
        case .cancelled, .failed:
            return true
        default:
            return false
        }
    }

    private func waitForReady(_ connection: NWConnection, timeout: TimeInterval = 20) async throws {
        if isDead(connection) { throw ProxyWebSocket.ConnectionError.closed }
        if connection.state == .ready { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ProxyOnceFlag()
            let timer = DispatchWorkItem {
                if once.trySet() {
                    connection.cancel()
                    cont.resume(throwing: ProxyTimeoutError())
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.trySet() else { return }
                    timer.cancel()
                    connection.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error):
                    guard once.trySet() else { return }
                    timer.cancel()
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .cancelled:
                    guard once.trySet() else { return }
                    timer.cancel()
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: CancellationError())
                default:
                    break
                }
            }
        }
    }

    private func receiveExact(_ connection: NWConnection, count: Int, timeout: TimeInterval = 15) async throws -> Data {
        guard !isDead(connection),
              connection.state == .ready || connection.state == .preparing else {
            throw ProxyWebSocket.ConnectionError.closed
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = ProxyOnceFlag()
            let timer = DispatchWorkItem {
                if once.trySet() {
                    self.queue(for: connection).async { connection.cancel() }
                    cont.resume(throwing: ProxyTimeoutError())
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
            queue(for: connection).async {
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    guard once.trySet() else { return }
                    timer.cancel()
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, data.count == count {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: ProxyWebSocket.ConnectionError.closed)
                    }
                }
            }
        }
    }

    private func receiveData(_ connection: NWConnection, maxLength: Int, timeout: TimeInterval = 300) async throws -> Data {
        guard !isDead(connection) else { throw ProxyWebSocket.ConnectionError.closed }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = ProxyOnceFlag()
            let timer = DispatchWorkItem {
                if once.trySet() {
                    connection.cancel()
                    cont.resume(throwing: ProxyTimeoutError())
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
            queue(for: connection).async {
                connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                    guard once.trySet() else { return }
                    timer.cancel()
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(returning: Data())
                    } else {
                        cont.resume(throwing: ProxyWebSocket.ConnectionError.closed)
                    }
                }
            }
        }
    }

    private func sendData(_ connection: NWConnection, data: Data, timeout: TimeInterval = 20) async throws {
        guard !isDead(connection) else { throw ProxyWebSocket.ConnectionError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ProxyOnceFlag()
            let timer = DispatchWorkItem {
                if once.trySet() {
                    connection.cancel()
                    cont.resume(throwing: ProxyTimeoutError())
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
            queue(for: connection).async {
                connection.send(content: data, completion: .contentProcessed { error in
                    guard once.trySet() else { return }
                    timer.cancel()
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
            }
        }
    }

}
