import Foundation

/// Deferred network ignition: the TDLib core is not started automatically on
/// devices (its HTTPS stack currently crashes in BoringSSL). The UI boots in a
/// safe offline mode; the live session is started explicitly from the hidden
/// Developer menu.
enum NetworkIgnition {
    static let key = "tdlibForceStart"

    static var isLiveRequested: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func requestLiveStart() {
        UserDefaults.standard.set(true, forKey: key)
        CallDiag.log("network ignition: live start requested from developer menu")
    }

    static var shouldStartAutomatically: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return isLiveRequested
        #endif
    }
}
