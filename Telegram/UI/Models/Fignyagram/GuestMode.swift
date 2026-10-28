import Combine
import LocalAuthentication
import SwiftUI
import UIKit

/// "Double bottom": an instantly switchable clean profile view.
///
/// A second encrypted TDLib database cannot be created without a second login,
/// so this mode hides every trace of the real profile instead: chats, search,
/// settings, developer tools and the terminal are replaced by an empty shell.
/// Leaving the mode requires biometrics, so a quick glance at the phone reveals
/// nothing.
@MainActor
final class GuestMode: ObservableObject {
    static let shared = GuestMode()

    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    private init() {}

    func enter() {
        guard !isActive else { return }
        isActive = true
        CallDiag.log("guest mode entered")
    }

    func requestExit() async {
        let context = LAContext()
        context.localizedFallbackTitle = NSLocalizedString("Generated.615052720d1f", comment: "")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = error?.localizedDescription
            return
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: NSLocalizedString("Generated.5f069510f933", comment: ""))
            if ok {
                isActive = false
                CallDiag.log("guest mode exited")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// The shell that is shown instead of the real interface in guest mode.
struct GuestModeView: View {
    @ObservedObject private var guest = GuestMode.shared

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text(L10n.t("Guest.Welcome"))
                .font(.title3.bold())
            Text(L10n.t("Guest.Empty"))
                .font(.appFootnote)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                Task { await guest.requestExit() }
            } label: {
                Text(L10n.t("Guest.Unlock"))
                    .font(.appFootnote)
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 2) {
            Task { await guest.requestExit() }
        }
    }
}
