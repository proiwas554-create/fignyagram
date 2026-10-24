import SwiftUI

struct GlassListModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .scrollContentBackground(.hidden)
                .background {
                    GlassBackgroundView(cornerRadius: 0).ignoresSafeArea()
                }
        } else {
            content
        }
    }
}
