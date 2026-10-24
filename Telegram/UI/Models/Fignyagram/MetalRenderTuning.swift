import Foundation
import QuartzCore
import Metal

/// Metal-side tuning for the chat texture pipeline.
///
/// SwiftUI owns the `.drawingGroup()` Metal context and does not expose its
/// MTLCommandQueue, so the OS decides queue priority. What we control:
///  - frame pacing: `CADisableMinimumFrameDurationOnPhone = true` (Info.plist)
///    unlocks ProMotion, letting the display link drive 120 Hz;
///  - texture memory: keep offscreen row textures framebuffer-only so the GPU
///    keeps them in tile memory instead of round-tripping to system RAM.
enum MetalRenderTuning {
    /// Call once at launch for any CAMetalLayer we create ourselves (used by
    /// the upcoming sticker/gif renderer). Settings minimize frame pacing
    /// jitter on ProMotion panels.
    static func configure(_ layer: CAMetalLayer, maximumFrames: Int = 3) {
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        layer.isOpaque = true
        layer.maximumDrawableCount = maximumFrames
        layer.allowsNextDrawableTimeout = true
        // Drawable size follows the layer, never the app's assumptions.
        layer.drawableSize = CGSize(
            width: layer.bounds.width * layer.contentsScale,
            height: layer.bounds.height * layer.contentsScale
        )
    }

    /// Create a command queue for our own Metal work with maximum pipeline
    /// parallelism; SwiftUI's queue is separate and untouched.
    static func makeCommandQueue(device: MTLDevice, label: String) -> MTLCommandQueue {
        let queue = device.makeCommandQueue()!
        queue.label = label
        return queue
    }

    /// Commit a frame and present it in the same display cycle to avoid a
    /// one-frame latency bubble (the "cyclic spike" pattern in Instruments).
    static func commit(_ buffer: MTLCommandBuffer, drawable: CAMetalDrawable) {
        buffer.present(drawable)
        buffer.commit()
    }
}
