#if targetEnvironment(macCatalyst)
import Foundation
import UIKit

/// Catalyst build has no WebRTC engine yet; this stub keeps the call layer
/// compiling and reporting "engine unavailable" so calls are disabled.
final class VoIPBridge: NSObject {
    static let sharedInstance = VoIPBridge()
    @objc static func shared() -> VoIPBridge { sharedInstance }
    @objc static func engineAvailable() -> Bool { false }

    var signalingDataHandler: ((Data) -> Void)?
    var remoteAudioHandler: ((Bool) -> Void)?
    var remoteVideoFirstFrameHandler: (() -> Void)?
    var localVideoFirstFrameHandler: (() -> Void)?
    var signalBarsHandler: ((Int) -> Void)?
    var stateHandler: ((Int) -> Void)?
    var stateText: String = "unavailable"

    @objc func configureProxy(withHost host: String, port: UInt16, username: String, password: String) {}
    @objc(configureCallWithServerConfig:customParameters:allowP2P:maxLayer:libraryVersions:)
    func configureCall(withServerConfig serverConfig: String, customParameters: String, allowP2P: Bool,
                       maxLayer: Int32, libraryVersions: [String]) {}
    @objc(startCallWithKey:isOutgoing:isVideo:servers:localView:remoteView:)
    func startCall(withKey key: Data, isOutgoing: Bool, isVideo: Bool,
                   servers: [[String: Any]], localView: UIView?, remoteView: UIView?) -> Bool { false }
    @objc func receiveSignalingData(_ data: Data) {}
    @objc func receiveSignaling(_ data: Data) {}
    @objc func setGroupCallMuted(_ muted: Bool) {}
    @objc(enableGroupVideoWithLocalView:remoteView:)
    func enableGroupVideo(withLocalView localView: UIView, remoteView: UIView) {}
    @objc(addGroupRemoteVideoForEndpoint:)
    func addGroupRemoteVideo(forEndpoint endpointId: String) {}
    @objc func setMicMute(_ mute: Bool) {}
    @objc func setVideoEnabled(_ enabled: Bool) {}
    @objc func setVideoRotationOffset(_ steps: Int) {}
    @objc func setVideoFlip(_ flip: Bool) {}
    @objc func setVideoFillsScreen(_ fill: Bool) {}
    @objc func setVideoMaximumFramesPerSecond(_ fps: Int) {}
    @objc func stopCall() {}
    @objc func switchCamera() {}
    @objc func setVideoPaused(_ paused: Bool) {}
    @objc func setAudioOutput(_ speaker: Bool) {}
}
#endif
