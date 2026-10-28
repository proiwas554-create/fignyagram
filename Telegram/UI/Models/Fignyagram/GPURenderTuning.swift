import SwiftUI
import UIKit

/// Flattens a row into a single GPU texture while the finger is moving, so the
/// render server only moves bitmaps instead of re-laying out every subview.
struct RasterizeOnScroll: ViewModifier {
    @ObservedObject private var scroll = ScrollActivity.shared

    func body(content: Content) -> some View {
        if scroll.isScrolling, !DevicePerformance.isLowMemory {
            content
                .drawingGroup(opaque: false)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
        } else {
            content
        }
    }
}

extension View {
    func rasterizeOnScroll() -> some View { modifier(RasterizeOnScroll()) }
}
