import SwiftUI
import UIKit

struct GlassBackgroundView: UIViewRepresentable {
    var cornerRadius: CGFloat

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView()
        if #available(iOS 26.0, *) {
            view.effect = UIGlassEffect(style: .regular)
        } else {
            view.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.layer.cornerRadius = cornerRadius
    }
}

private struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let onlyNormal: Bool
    @ObservedObject private var classic = ClassicDesignMode.shared

    func body(content: Content) -> some View {
        if onlyNormal && classic.isEnabled {
            content
        } else {
            content
                .background {
                    GlassBackgroundView(cornerRadius: cornerRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(Color.white.opacity(0.04))
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 18, onlyNormal: Bool = true) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, onlyNormal: onlyNormal))
    }
}
