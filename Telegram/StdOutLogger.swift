import Foundation
import TDLibKit

/// Печатает всё, что делает TDLib, в консоль Xcode.
final class StdOutLogger: TDLibLogger {

    private let queue = DispatchQueue(label: "Fignyagram.Logger", qos: .utility)

    func log(_ message: String, type: LoggerMessageType?) {
        queue.async {
            let prefix: String
            switch type {
            case .send:    prefix = "⬆️ SEND"
            case .receive: prefix = "⬇️ RECV"
            case .execute: prefix = "⚙️ EXEC"
            default:       prefix = "📝 LOG "
            }
            print("\(prefix) | \(message)")
        }
    }
}
