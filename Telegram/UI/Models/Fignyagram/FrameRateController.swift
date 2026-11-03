import Foundation
import QuartzCore

/// Fixed frame-rate limit ("Fixed FPS"): when enabled, every CADisplayLink in
/// the app is pinned to the selected rate; otherwise ProMotion stays unlocked.
@MainActor
enum FrameRateController {
    static let fixedEnabledKey = "isFixedFPSEnabled"
    static let fixedValueKey = "fixedFPSValue"

    private static var links: [WeakLink] = []
    private static var governor: CADisplayLink?

    private struct WeakLink {
        weak var link: CADisplayLink?
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: fixedEnabledKey)
    }

    static var value: Int {
        let stored = UserDefaults.standard.integer(forKey: fixedValueKey)
        return stored > 0 ? stored : 60
    }

    static var range: CAFrameRateRange {
        if isEnabled {
            let fps = Float(value)
            return CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        }
        return CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    }

    static func register(_ link: CADisplayLink) {
        links.removeAll { $0.link == nil }
        links.append(WeakLink(link: link))
        applyRange(to: link)
    }

    /// Catalyst inherits an iPad-like 60 Hz cap from UIKit. On a real Mac the
    /// display link is pushed to the desktop cadence (ProMotion up to 120 Hz),
    /// unless the user explicitly pinned a fixed FPS.
    static func applyRange(to link: CADisplayLink) {
        guard #available(iOS 15.0, *) else { return }
        if DeveloperMonitor.shared.isRunningOnTrueMac && !isEnabled {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        } else {
            link.preferredFrameRateRange = range
        }
    }

    /// A long-lived display link keeps the requested cadence applied to
    /// app-driven CoreAnimation. iOS exposes no public switch for the panel's
    /// refresh rate, so system rendering stays at the display's own rate.
    static func startGovernor() {
        guard #available(iOS 16.0, *) else { return }
        guard governor == nil else { refreshActiveLinks(); return }
        let link = CADisplayLink(target: GovernorTarget.shared, selector: #selector(GovernorTarget.tick))
        applyRange(to: link)
        link.add(to: .main, forMode: .common)
        governor = link
    }

    static func refreshActiveLinks() {
        if let governor {
            applyRange(to: governor)
        }
        links.removeAll { $0.link == nil }
        for item in links {
            if let link = item.link { applyRange(to: link) }
        }
    }
}


@MainActor
private final class GovernorTarget: NSObject {
    static let shared = GovernorTarget()
    @objc func tick() {}
}
