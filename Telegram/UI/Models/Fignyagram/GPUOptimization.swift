import Foundation
import UIKit
import QuartzCore
import Metal
import CoreImage

/// Asks ProMotion to run at the maximum refresh rate for the app and keeps a
/// GPU-backed CoreImage context ready for image effects. This splits work:
/// CoreAnimation/Metal on the GPU, thumbnail decode on the E-core queue, and
/// SwiftUI layout on the main thread with a 120 Hz display link.
@MainActor
final class GPUOptimization {
    static let shared = GPUOptimization()

    private var displayLink: CADisplayLink?
    private(set) var metalDevice: MTLDevice?
    private(set) var ciContext: CIContext?

    private init() {
        metalDevice = MTLCreateSystemDefaultDevice()
        if let metalDevice {
            ciContext = CIContext(mtlDevice: metalDevice, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        }
    }

    /// Prepares GPU resources and applies legacy tuning. No CADisplayLink is
    /// kept: an idle 120 Hz link forced ProMotion into a fixed cadence and
    /// lowered measured FPS. CoreAnimation owns the cadence now.
    func start() {
        if DevicePerformance.isLowMemory || UIScreen.main.maximumFramesPerSecond <= 60 {
            ImageCache.applyLegacyDeviceTuning()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

private final class DisplayLinkProxy: NSObject {
    static let shared = DisplayLinkProxy()
    @objc func tick() {}
}

/// Batches many list mutations into a single CoreAnimation transaction so the
/// GPU composites the update once instead of animating every intermediate
/// state (mass chat-list updates, search results).
enum RenderBatch {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "renderBatchingEnabled") as? Bool ?? true
    }

    static func perform(_ updates: () -> Void) {
        guard isEnabled else { updates(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }
}
