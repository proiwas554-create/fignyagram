import SwiftUI
import UIKit

/// Video calls are rendered in a dedicated window below the call UI window.
/// This is the only way to guarantee a full-screen video surface: SwiftUI keeps
/// resizing the view when it hosts it, while a window owns the exact screen.
@MainActor
final class CallWindows {
    static let shared = CallWindows()

    private var videoWindow: UIWindow?
    private var uiWindow: UIWindow?
    private var container: UIView?
    private var hosting: UIHostingController<CallView>?

    func show(video: Bool) {
        CallDiag.log("call windows show video=\(video)")
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        if video {
            if videoWindow == nil {
                let window = UIWindow(windowScene: scene)
                window.windowLevel = .normal + 1
                window.backgroundColor = .black
                let root = VideoWindowRoot()
                root.view.backgroundColor = .black
                window.rootViewController = root
                videoWindow = window
                let container = UIView(frame: window.bounds)
                container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                root.view.addSubview(container)
                self.container = container
            }
            videoWindow?.isHidden = false
            videoWindow?.frame = UIScreen.main.bounds
        }
        if uiWindow == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .normal + 2
            window.backgroundColor = .clear
            let host = UIHostingController(rootView: CallView(windowHosted: true))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            uiWindow = window
            hosting = host
        }
        uiWindow?.isHidden = false
        uiWindow?.frame = UIScreen.main.bounds
        uiWindow?.makeKeyAndVisible()
        if video { videoWindow?.isHidden = false }
        layoutVideo()
    }

    func hide() {
        uiWindow?.isHidden = true
        videoWindow?.isHidden = true
        uiWindow = nil
        videoWindow = nil
        hosting = nil
        container = nil
    }

    private var lastLoggedSize: CGSize = .zero

    func layoutVideo() {
        guard let container else { return }
        if let window = container.window {
            container.frame = window.bounds
        }
        let bounds = container.bounds
        guard bounds.width > 0 else { return }
        let callManager = CallManager.shared
        let active = callManager.showSelfAsMain ? callManager.localView : callManager.remoteView
        let secondary = callManager.showSelfAsMain ? callManager.remoteView : callManager.localView
        container.backgroundColor = .black
        for view in [callManager.localView, callManager.remoteView].compactMap({ $0 }) where view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view)
        }
        if let active {
            active.frame = bounds
            active.layer.cornerRadius = 0
            active.clipsToBounds = true
        }
        if bounds.size != lastLoggedSize {
            lastLoggedSize = bounds.size
            CallDiag.log("video window: container=\(Int(bounds.width))x\(Int(bounds.height)) " +
                         "window=\(Int(container.window?.frame.width ?? 0))x\(Int(container.window?.frame.height ?? 0)) " +
                         "level=\(container.window?.windowLevel.rawValue ?? 0) hidden=\(container.window?.isHidden ?? true) " +
                         "active=\(active.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil")")
        }
        if let secondary {
            let card = CGRect(x: bounds.width - 104 - 14,
                              y: 96,
                              width: 104,
                              height: 148)
            secondary.frame = card
            secondary.layer.cornerRadius = 14
            secondary.layer.borderWidth = 1
            secondary.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
            secondary.clipsToBounds = true
            container.bringSubviewToFront(secondary)
        }
    }
}


/// Relays size changes of the video window to the layout of the streams.
private final class VideoWindowRoot: UIViewController {
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CallWindows.shared.layoutVideo()
    }
}
