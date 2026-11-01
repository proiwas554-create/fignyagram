import Foundation
import os.log

private let proxySocketLogger = Logger(subsystem: "com.fignyagram.app", category: "ProxyWebSocket")

nonisolated struct ProxyWebSocketError: Error {
    let statusCode: Int
    let statusLine: String
    let headers: [String: String]
    let location: String?
    var isRedirect: Bool { [301, 302, 303, 307, 308].contains(statusCode) }
}

/// WebSocket over URLSessionStreamTask: goes through nsurlsessiond, which is
/// not affected by the per-process socket isolation seen with NWConnection on
/// iOS 26/27 (connection stayed in .preparing forever).
actor ProxyWebSocket {
    enum ConnectionError: Error { case closed, timeout, badHandshake }
    let connectionID: Int64 = HandlerIDGenerator.shared.next

    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private var closed = false

    init() {}

    static func connect(ip: String, domain: String, path: String = "/apiws",
                        timeout: TimeInterval = 20.0) async throws -> ProxyWebSocket {
        try await connect(domain: domain, path: path, timeout: timeout)
    }
    static func connect(ip: String, domain: String, path: String = "/apiws",
                        port: Int, timeout: TimeInterval = 20.0) async throws -> ProxyWebSocket {
        try await connect(domain: domain, path: path, port: port, timeout: timeout)
    }
    static func connect(domain: String, path: String = "/apiws",
                        timeout: TimeInterval = 20.0) async throws -> ProxyWebSocket {
        try await connect(domain: domain, path: path, port: 443, timeout: timeout)
    }

    static func connect(domain: String, path: String = "/apiws",
                        port: Int, timeout: TimeInterval = 20.0) async throws -> ProxyWebSocket {
        let socket = ProxyWebSocket()
        do {
            try await socket.open(host: domain, path: path, port: port, timeout: timeout)
            return socket
        } catch {
            await socket.close()
            throw error
        }
    }

    private func open(host: String, path: String, port: Int, timeout: TimeInterval) async throws {
        let delegate = StreamDelegateBox()
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.streamTask(withHostName: host, port: port)
        self.session = session
        self.task = task

        try await withTimeout(seconds: timeout) {
            task.resume()
            task.startSecureConnection()
            try await delegate.waitReady()
        }
        CallDiag.log("stream tls \\(host):\\(port)")

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let upgrade = "GET \\(path) HTTP/1.1\r\n" +
            "Host: \\(host)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \\(key)\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "Sec-WebSocket-Protocol: binary\r\n" +
            "Origin: https://web.telegram.org\r\n" +
            "User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15\r\n\r\n"
        try await write(Data(upgrade.utf8))
        let header = try await readHTTPHead()
        guard header.contains(" 101 ") else {
            let statusLine = header.components(separatedBy: "\r\n").first ?? ""
            CallDiag.log("stream upgrade fail \(host) \(statusLine)")
            throw ConnectionError.badHandshake
        }
        proxySocketLogger.info("[WS#\\(self.connectionID)] stream connected \\(host)\\(path)")
        CallDiag.log("stream open \\(host)\\(path) id=\\(self.connectionID)")
    }

    private func readHTTPHead() async throws -> String {
        var data = Data()
        while data.count < 16_384 {
            let chunk = try await read(max: 1024)
            if chunk.isEmpty { break }
            data.append(chunk)
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                return String(decoding: data[..<range.upperBound], as: UTF8.self)
            }
        }
        throw ConnectionError.badHandshake
    }

    private func read(max: Int) async throws -> Data {
        guard let task, !closed else { throw ConnectionError.closed }
        return try await withCheckedThrowingContinuation { cont in
            task.readData(ofMinLength: 1, maxLength: max, timeout: 20) { data, atEOF, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: data ?? Data()) }
            }
        }
    }

    private func readExact(_ count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            let chunk = try await read(max: count - out.count)
            if chunk.isEmpty { throw ConnectionError.closed }
            out.append(chunk)
        }
        return out
    }

    private func write(_ data: Data) async throws {
        guard let task, !closed else { throw ConnectionError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: 20) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func frame(_ payload: Data, opcode: UInt8 = 0x2) -> Data {
        var out = Data([0x80 | opcode])
        let mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
        if payload.count < 126 {
            out.append(UInt8(payload.count) | 0x80)
        } else if payload.count <= 0xFFFF {
            out.append(126 | 0x80)
            out.append(UInt8((payload.count >> 8) & 0xFF))
            out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(127 | 0x80)
            let n = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((n >> UInt64(shift)) & 0xFF)) }
        }
        out.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() { out.append(byte ^ mask[i % 4]) }
        return out
    }

    func send(_ data: Data) async throws { try await write(frame(data)) }
    func sendBatch(_ parts: [Data]) async throws { for part in parts { try await send(part) } }

    func ping() async throws {
        try await write(frame(Data(), opcode: 0x9))
    }

    func recv() async throws -> Data? {
        let head = try await readExact(2)
        let bytes = [UInt8](head)
        var length = Int(bytes[1] & 0x7F)
        if length == 126 {
            let ext = [UInt8](try await readExact(2))
            length = Int(ext[0]) << 8 | Int(ext[1])
        } else if length == 127 {
            let ext = [UInt8](try await readExact(8))
            length = 0
            for b in ext { length = (length << 8) | Int(b) }
        }
        let opcode = bytes[0] & 0x0F
        let payload = length > 0 ? try await readExact(length) : Data()
        switch opcode {
        case 0x1, 0x2: return payload
        case 0x8: closed = true; return nil
        case 0x9: try await write(frame(payload, opcode: 0xA)); return try await recv()
        default: return try await recv()
        }
    }

    func close() async {
        closed = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func withTimeout<T>(seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ProxyTimeoutError()
            }
            guard let result = try await group.next() else { throw ProxyTimeoutError() }
            group.cancelAll()
            return result
        }
    }
}

private final class StreamDelegateBox: NSObject, URLSessionStreamDelegate {
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var ready = false
    func waitReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { cont in
            readyContinuations.append(cont)
        }
    }
    func urlSession(_ session: URLSession, streamTask: URLSessionStreamTask,
                    didBecome inputStream: InputStream, outputStream: OutputStream) {
        ready = true
        let conts = readyContinuations
        readyContinuations = []
        conts.forEach { $0.resume() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let conts = readyContinuations
        readyContinuations = []
        conts.forEach { $0.resume(throwing: error ?? ProxyTimeoutError()) }
    }
}
