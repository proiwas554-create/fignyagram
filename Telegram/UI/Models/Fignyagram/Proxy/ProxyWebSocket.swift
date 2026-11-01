import Foundation
import Network
import os.log

private let proxySocketLogger = Logger(subsystem: "com.fignyagram.app", category: "ProxyWebSocket")

nonisolated struct ProxyWebSocketError: Error {
    let statusCode: Int
    let statusLine: String
    let headers: [String: String]
    let location: String?

    var isRedirect: Bool { [301, 302, 303, 307, 308].contains(statusCode) }
}

/// Raw WebSocket client over NWConnection. This is the transport that worked
/// with the Cloudflare frontends: it sends the exact upgrade headers Telegram
/// expects and keeps every NWConnection call on the queue passed to start().
actor ProxyWebSocket {
    enum ConnectionError: Error { case closed, timeout }

    static let opBinary: UInt8 = 0x2
    static let opClose: UInt8 = 0x8
    static let opPing: UInt8 = 0x9
    static let opPong: UInt8 = 0xA

    let connectionID: Int64 = HandlerIDGenerator.shared.next

    private var connection: NWConnection?
    private var isClosed = false
    private var receiveBuffer = Data()
    private let connectionQueue: DispatchQueue

    init() {
        connectionQueue = DispatchQueue(label: "Fignyagram.ws.\(HandlerIDGenerator.shared.next)")
    }

    // MARK: - Connect

    static func connect(ip: String, domain: String, path: String = "/apiws",
                        timeout: TimeInterval = 20.0) async throws -> ProxyWebSocket {
        try await connect(ip: ip, domain: domain, path: path, port: 443, timeout: timeout)
    }

    static func connect(ip: String, domain: String, path: String = "/apiws",
                        port: Int, timeout: TimeInterval = 20.0) async throws -> ProxyWebSocket {
        let socket = ProxyWebSocket()
        do {
            try await socket.performConnect(ip: ip, domain: domain, path: path, port: port, timeout: timeout)
            return socket
        } catch {
            await socket.hardReset(sendCloseFrame: false)
            throw error
        }
    }

    static func connect(domain: String, path: String = "/apiws",
                        timeout: TimeInterval = 20.0) async throws -> ProxyWebSocket {
        try await connect(domain: domain, path: path, port: 443, timeout: timeout)
    }

    static func connect(domain: String, path: String = "/apiws",
                        port: Int, timeout: TimeInterval = 20.0) async throws -> ProxyWebSocket {
        let socket = ProxyWebSocket()
        do {
            try await socket.performConnect(ip: nil, domain: domain, path: path, port: port, timeout: timeout)
            return socket
        } catch {
            await socket.hardReset(sendCloseFrame: false)
            throw error
        }
    }

    private func performConnect(ip: String?, domain: String, path: String,
                                port: Int, timeout: TimeInterval) async throws {
        var tlsOptions: NWProtocolTLS.Options?
        if port == 443 {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, domain)
            tlsOptions = options
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = Int(timeout)

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ProxyWebSocketError(statusCode: 0, statusLine: "bad port", headers: [:], location: nil)
        }
        let host = ip.map { NWEndpoint.Host($0) } ?? NWEndpoint.Host(domain)
        let conn = NWConnection(to: NWEndpoint.hostPort(host: host, port: endpointPort), using: params)
        connection = conn

        proxySocketLogger.info("[WS#\(self.connectionID)] connect \(domain):\(port)")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ProxyOnceFlag()
            let timer = DispatchWorkItem {
                if once.trySet() {
                    self.connectionQueue.async { conn.cancel() }
                    cont.resume(throwing: ProxyTimeoutError())
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
            connectionQueue.async {
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        guard once.trySet() else { return }
                        timer.cancel()
                        conn.stateUpdateHandler = nil
                        cont.resume()
                    case .failed(let error):
                        guard once.trySet() else { return }
                        timer.cancel()
                        conn.stateUpdateHandler = nil
                        cont.resume(throwing: error)
                    case .cancelled:
                        guard once.trySet() else { return }
                        timer.cancel()
                        conn.stateUpdateHandler = nil
                        cont.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                conn.start(queue: self.connectionQueue)
            }
        }

        let wsKey = Data(proxySecureRandomBytes(16)).base64EncodedString()
        let request = [
            "GET \(path) HTTP/1.1",
            "Host: \(domain)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(wsKey)",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: binary",
            "Origin: https://web.telegram.org",
            "User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            "",
            ""
        ].joined(separator: "\r\n")

        try await sendRaw(Data(request.utf8), timeout: timeout)

        var responseData = Data()
        while true {
            let chunk = try await receiveRaw(maxLength: 4096, timeout: timeout)
            responseData.append(chunk)
            if responseData.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if responseData.count > 128 * 1024 {
                throw ProxyWebSocketError(statusCode: 0, statusLine: "response too large", headers: [:], location: nil)
            }
        }

        guard let responseText = String(data: responseData, encoding: .utf8) else {
            throw ProxyWebSocketError(statusCode: 0, statusLine: "invalid response", headers: [:], location: nil)
        }
        let lines = responseText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw ProxyWebSocketError(statusCode: 0, statusLine: "empty response", headers: [:], location: nil)
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        let statusCode = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0

        if statusCode == 101 {
            if let headerEnd = responseData.range(of: Data("\r\n\r\n".utf8)) {
                let remaining = responseData.suffix(from: headerEnd.upperBound)
                if !remaining.isEmpty { receiveBuffer.append(remaining) }
            }
            proxySocketLogger.info("[WS#\(self.connectionID)] handshake ok \(domain)")
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        await hardReset(sendCloseFrame: false)
        throw ProxyWebSocketError(statusCode: statusCode, statusLine: statusLine,
                                  headers: headers, location: headers["location"])
    }

    // MARK: - Send / recv

    func send(_ data: Data) async throws {
        guard !isClosed else { throw ConnectionError.closed }
        try await sendRaw(buildFrame(opcode: Self.opBinary, data: data, mask: true))
    }

    func sendBatch(_ parts: [Data]) async throws {
        guard !isClosed else { throw ConnectionError.closed }
        var combined = Data()
        for part in parts {
            combined.append(buildFrame(opcode: Self.opBinary, data: part, mask: true))
        }
        try await sendRaw(combined)
    }

    func ping() async throws {
        guard !isClosed else { throw ConnectionError.closed }
        try await sendRaw(buildFrame(opcode: Self.opPing, data: Data(), mask: true))
    }

    func recv() async throws -> Data? {
        while !isClosed {
            let frame = try await readFrame()
            switch frame.opcode {
            case Self.opClose:
                isClosed = true
                return nil
            case Self.opPing:
                try? await sendRaw(buildFrame(opcode: Self.opPong, data: frame.payload, mask: true))
                await Task.yield()
                continue
            case Self.opPong:
                await Task.yield()
                continue
            case 0x1, 0x2:
                var payload = frame.payload
                var isFinal = frame.isFinal
                while !isFinal {
                    let next = try await readFrame()
                    switch next.opcode {
                    case Self.opPing:
                        try? await sendRaw(buildFrame(opcode: Self.opPong, data: next.payload, mask: true))
                    case Self.opPong:
                        break
                    case Self.opClose:
                        isClosed = true
                        return nil
                    case 0x0:
                        payload.append(next.payload)
                        isFinal = next.isFinal
                    default:
                        await Task.yield()
                    }
                }
                return payload
            default:
                await Task.yield()
                continue
            }
        }
        return nil
    }

    func close() async { await hardReset(sendCloseFrame: true) }

    func hardReset(sendCloseFrame: Bool = true) {
        guard !isClosed || connection != nil else { return }
        isClosed = true
        if sendCloseFrame {
            let frame = buildFrame(opcode: Self.opClose, data: Data(), mask: true)
            connectionQueue.async { [weak self] in
                self?.connection?.send(content: frame, completion: .contentProcessed { _ in })
                self?.connection?.cancel()
            }
        } else {
            connectionQueue.async { [weak self] in
                self?.connection?.stateUpdateHandler = nil
                self?.connection?.cancel()
            }
        }
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Low-level I/O (all on connectionQueue)

    private func sendRaw(_ data: Data, timeout: TimeInterval = 20) async throws {
        guard let conn = connection, !isDead(conn) else { throw ConnectionError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ProxyOnceFlag()
            let timer = DispatchWorkItem {
                if once.trySet() {
                    self.connectionQueue.async { conn.cancel() }
                    cont.resume(throwing: ProxyTimeoutError())
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
            connectionQueue.async {
                conn.send(content: data, completion: .contentProcessed { error in
                    guard once.trySet() else { return }
                    timer.cancel()
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }
    }

    private func receiveRaw(maxLength: Int, timeout: TimeInterval = 300) async throws -> Data {
        guard let conn = connection, !isDead(conn) else { throw ConnectionError.closed }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = ProxyOnceFlag()
            let timer = DispatchWorkItem {
                if once.trySet() {
                    self.connectionQueue.async { conn.cancel() }
                    cont.resume(throwing: ProxyTimeoutError())
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
            connectionQueue.async {
                conn.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
                    guard once.trySet() else { return }
                    timer.cancel()
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else {
                        cont.resume(throwing: ConnectionError.closed)
                    }
                }
            }
        }
    }

    private func isDead(_ conn: NWConnection) -> Bool {
        switch conn.state {
        case .cancelled, .failed: return true
        default: return false
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        while receiveBuffer.count < count {
            let chunk = try await receiveRaw(maxLength: 65536)
            receiveBuffer.append(chunk)
        }
        let result = receiveBuffer.prefix(count)
        receiveBuffer.removeFirst(count)
        return Data(result)
    }

    // MARK: - Framing

    private func buildFrame(opcode: UInt8, data: Data, mask: Bool) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)
        var payload = data
        if mask {
            let maskKey = proxySecureRandomBytes(4)
            var masked = Data()
            masked.reserveCapacity(payload.count)
            for (i, byte) in payload.enumerated() {
                masked.append(byte ^ maskKey[i % 4])
            }
            payload = masked
            let length = UInt64(payload.count)
            var lengthBytes = Data()
            if length < 126 {
                lengthBytes.append(UInt8(length))
            } else if length <= 0xFFFF {
                lengthBytes.append(126)
                lengthBytes.append(UInt8((length >> 8) & 0xFF))
                lengthBytes.append(UInt8(length & 0xFF))
            } else {
                lengthBytes.append(127)
                for shift in stride(from: 56, through: 0, by: -8) {
                    lengthBytes.append(UInt8((length >> UInt64(shift)) & 0xFF))
                }
            }
            frame.append(0x80 | (lengthBytes.first ?? 0))
            frame.append(lengthBytes.dropFirst())
            frame.append(contentsOf: maskKey)
        } else {
            let length = UInt64(payload.count)
            if length < 126 {
                frame.append(UInt8(length))
            } else if length <= 0xFFFF {
                frame.append(126)
                frame.append(UInt8((length >> 8) & 0xFF))
                frame.append(UInt8(length & 0xFF))
            } else {
                frame.append(127)
                for shift in stride(from: 56, through: 0, by: -8) {
                    frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
                }
            }
        }
        frame.append(payload)
        return frame
    }

    private struct Frame {
        var opcode: UInt8
        var payload: Data
        var isFinal: Bool
    }

    private func readFrame() async throws -> Frame {
        let first = try await receiveExactly(2)
        let byte0 = first[first.startIndex]
        let byte1 = first[first.startIndex + 1]
        let isFinal = (byte0 & 0x80) != 0
        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        var length = UInt64(byte1 & 0x7F)

        if length == 126 {
            let ext = try await receiveExactly(2)
            length = UInt64(ext[ext.startIndex]) << 8 | UInt64(ext[ext.startIndex + 1])
        } else if length == 127 {
            let ext = try await receiveExactly(8)
            length = 0
            for byte in ext { length = length << 8 | UInt64(byte) }
        }

        var maskKey: Data?
        if masked {
            maskKey = try await receiveExactly(4)
        }

        let payload = try await receiveExactly(Int(length))
        var result = payload
        if let maskKey {
            var unmasked = Data()
            unmasked.reserveCapacity(result.count)
            for (i, byte) in result.enumerated() {
                unmasked.append(byte ^ maskKey[i % 4])
            }
            result = unmasked
        }
        return Frame(opcode: opcode, payload: result, isFinal: isFinal)
    }
}
