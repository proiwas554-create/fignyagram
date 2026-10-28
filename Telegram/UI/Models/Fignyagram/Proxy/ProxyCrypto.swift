import Foundation
import CommonCrypto
import Security

// Based on the MIT-licensed tg-ws-proxy by Flowseal
// (https://github.com/Flowseal/tg-ws-proxy) and its iOS port
// (https://github.com/NeonchikMPT/tgwsproxy-ios).
// Adapted for Fignyagram: namespaced, no dependency on the original app.

/// AES-256-CTR with a 16-byte big-endian counter, used by MTProto obfuscation.
nonisolated final class ProxyAESCTR {
    private let key: [UInt8]
    private var counter: [UInt8]
    private var keystream: [UInt8] = []
    private var keystreamOffset = 0

    init(key: [UInt8], iv: [UInt8]) {
        precondition(key.count == 32, "AES-256 key must be 32 bytes")
        precondition(iv.count == 16, "IV must be 16 bytes")
        self.key = key
        self.counter = iv
    }

    func process(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var offset = 0

        while offset < data.count {
            if keystreamOffset >= keystream.count {
                keystream = encryptBlock(counter)
                keystreamOffset = 0
                incrementCounter()
            }

            let available = keystream.count - keystreamOffset
            let needed = data.count - offset
            let chunk = min(available, needed)

            for i in 0..<chunk {
                out[offset + i] = data[offset + i] ^ keystream[keystreamOffset + i]
            }
            offset += chunk
            keystreamOffset += chunk
        }
        return out
    }

    func process(_ data: Data) -> Data {
        Data(process([UInt8](data)))
    }

    private func encryptBlock(_ block: [UInt8]) -> [UInt8] {
        var encrypted = [UInt8](repeating: 0, count: block.count + kCCBlockSizeAES128)
        var numBytesEncrypted: size_t = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            key, key.count,
            nil,
            block, block.count,
            &encrypted, encrypted.count,
            &numBytesEncrypted
        )
        precondition(status == kCCSuccess, "AES ECB encrypt failed: \(status)")
        return Array(encrypted.prefix(16))
    }

    private func incrementCounter() {
        for i in stride(from: 15, through: 0, by: -1) {
            counter[i] &+= 1
            if counter[i] != 0 { break }
        }
    }
}

nonisolated func proxySHA256(_ data: [UInt8]) -> [UInt8] {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256(data, CC_LONG(data.count), &hash)
    return hash
}

nonisolated func proxySecureRandomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return bytes
}

nonisolated func proxyHexToBytes(_ hex: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        if let byte = UInt8(hex[index..<next], radix: 16) {
            bytes.append(byte)
        }
        index = next
    }
    return bytes
}


/// Raised when a proxy network operation exceeds its deadline.
nonisolated struct ProxyTimeoutError: LocalizedError {
    let underlying: Error?

    init(underlying: Error? = nil) {
        self.underlying = underlying
    }

    var errorDescription: String? {
        let base = NSLocalizedString("Generated.f5547eb4fea3", comment: "")
        if let underlying, let description = (underlying as? LocalizedError)?.errorDescription {
            return base + " " + description
        }
        return base
    }
}


/// Thread-safe single-resume guard for continuations with timeouts.
nonisolated final class ProxyOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
