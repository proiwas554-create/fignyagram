import Foundation
import SwiftUI

/// "Frame economy": a real, measurable work reduction instead of pretending to
/// change the panel refresh rate (iOS does not allow that for third-party apps).
enum FrameSaver {
    static let key = "frameSaverEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}

extension View {
    /// Disables implicit/explicit animations while the economy mode is on.
    @ViewBuilder
    func frameSaverAware() -> some View {
        if FrameSaver.isEnabled {
            transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        } else {
            self
        }
    }
}
