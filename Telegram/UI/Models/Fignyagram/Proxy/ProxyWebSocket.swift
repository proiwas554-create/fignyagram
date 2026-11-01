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

/// WebSocket transport backed by the system stack (URLSessionWebSocketTask).
/// NWConnection stayed in `.preparing` forever on iOS 26/27 devices while
/// URLSession to the same Cloudflare host completed TLS successfully.
private final class WSOpenDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((Error?) -> Void)?
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) { onOpen?() }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(nil)
    }
}

actor ProxyWebSocket {
    enum ConnectionError: Error { case closed, timeout }

    let connectionID: Int64 = HandlerIDGenerator.shared.next

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
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
            try await socket.open(host: domain, path: path, timeout: timeout)
            return socket
        } catch {
            CallDiag.log("ws fail \(domain)\(path) \(String(describing: error))")
            await socket.close()
            throw error
        }
    }

    private func open(host: String, path: String, timeout: TimeInterval) async throws {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = path
        guard let url = components.url else { throw ConnectionError.closed }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        let delegate = WSOpenDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task

        try await withTimeout(seconds: timeout) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.onOpen = { continuation.resume() }
                delegate.onClose = { error in
                    continuation.resume(throwing: error ?? ProxyTimeoutError())
                }
                task.resume()
            }
        }
        proxySocketLogger.info("[WS#\(self.connectionID)] connected \(host)\(path)")
        CallDiag.log("ws open \(host)\(path) id=\(self.connectionID)")
    }

    func send(_ data: Data) async throws {
        guard let task, !closed else { throw ConnectionError.closed }
        try await task.send(.data(data))
    }

    func sendBatch(_ parts: [Data]) async throws {
        for part in parts { try await send(part) }
    }

    func ping() async throws {
        guard let task, !closed else { throw ConnectionError.closed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func recv() async throws -> Data? {
        guard let task, !closed else { return nil }
        let message = try await task.receive()
        switch message {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: return nil
        }
    }

    func close() async {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
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
