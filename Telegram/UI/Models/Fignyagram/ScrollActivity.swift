import Combine
import Foundation
import QuartzCore

/// Tracks whether a list is being dragged, so expensive background work
/// (translation prefetch, media decoding) is postponed until the finger stops.
@MainActor
final class ScrollActivity: ObservableObject {
    static let shared = ScrollActivity()

    @Published private(set) var isScrolling = false
    private var resetTask: Task<Void, Never>?

    private init() {}

    private var transactionOpen = false

    func begin() {
        resetTask?.cancel()
        if !isScrolling {
            isScrolling = true
            // Suppress implicit CoreAnimation animations for the duration of the
            // drag: every frame is committed as one monolithic transaction.
            if !transactionOpen {
                transactionOpen = true
                CATransaction.begin()
                CATransaction.setDisableActions(true)
            }
        }
    }

    func end() {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            self.isScrolling = false
            if self.transactionOpen {
                self.transactionOpen = false
                CATransaction.commit()
            }
        }
    }

    /// Waits until scrolling settles, then returns true (or false on timeout).
    func waitUntilIdle(maximum: UInt64 = 1_500_000_000) async -> Bool {
        var waited: UInt64 = 0
        while isScrolling, waited < maximum {
            try? await Task.sleep(nanoseconds: 80_000_000)
            waited += 80_000_000
        }
        return !isScrolling
    }
}
