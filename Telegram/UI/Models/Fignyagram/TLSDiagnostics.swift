import Foundation
import Network
import Security
import CryptoKit

/// Pre-flight TLS probe: connects to Telegram fronts before TDLib does and
/// dumps the server certificate parameters into call_diag.log. This lets us see
/// exactly which certificate makes BoringSSL abort inside TDLib.
enum TLSDiagnostics {
    static let hosts = ["kws1.web.telegram.org", "kws2.web.telegram.org",
                        "kws3.web.telegram.org", "web.telegram.org",
                        "cdn.telesco.pe"]

    static func probeAll() {
        for host in hosts {
            probe(host: host)
        }
    }

    private static func probe(host: String) {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: 443, using: params)
        let queue = DispatchQueue(label: "fny.tlsdiag.\(host)")
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                dump(host: host, trust: trust)
                complete(true)
            },
            queue
        )
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                CallDiag.log("tlsdiag \(host) failed \(error)")
            }
            if case .ready = state { connection.cancel() }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 6) { connection.cancel() }
    }

    private static func dump(host: String, trust: SecTrust) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            CallDiag.log("tlsdiag \(host): no certificate chain")
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let summary = SecCertificateCopySubjectSummary(leaf) as String? ?? "?"
        var keyInfo = "unknown"
        if let key = SecCertificateCopyKey(leaf),
           let attrs = SecKeyCopyAttributes(key) as? [String: Any] {
            let type = attrs[kSecAttrKeyType as String] as? String ?? "?"
            let bits = attrs[kSecAttrKeySizeInBits as String] as? Int ?? 0
            keyInfo = "\(type) \(bits)bit"
        }
        CallDiag.log("tlsdiag \(host) subj=\(summary) key=\(keyInfo) sha256=\(digest) chain=\(chain.count)")
    }
}
