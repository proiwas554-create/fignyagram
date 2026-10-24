import SwiftUI

struct ZoomableStickerModifier: ViewModifier {
    @State private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(max(value, 1), 3)
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.2)) { scale = 1 }
                    }
            )
            .zIndex(scale > 1 ? 2 : 0)
    }
}
