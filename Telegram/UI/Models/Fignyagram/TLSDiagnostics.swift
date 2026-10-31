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
        CallDiag.log("tlsdiag probe start hosts=\(hosts.count)")
        for host in hosts {
            probe(host: host)
            probeWithURLSession(host: host)
        }
    }

    private final class SessionDelegate: NSObject, URLSessionDelegate {
        let host: String
        init(host: String) { self.host = host }
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust {
                dump(host: host + "(urlsession)", trust: trust)
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private static var delegates: [SessionDelegate] = []

    private static func probeWithURLSession(host: String) {
        let delegate = SessionDelegate(host: host)
        delegates.append(delegate)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        session.dataTask(with: request) { _, _, error in
            if let error { CallDiag.log("tlsdiag \(host) urlsession error \(error.localizedDescription)") }
        }.resume()
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
            switch state {
            case .failed(let error):
                CallDiag.log("tlsdiag \(host) nw failed \(error)")
            case .ready:
                connection.cancel()
            default:
                break
            }
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
