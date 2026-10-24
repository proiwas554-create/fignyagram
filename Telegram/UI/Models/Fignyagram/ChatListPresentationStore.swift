import Foundation
import Combine

/// Debounced builder for the chat list rows. ChatStore ticks (typing statuses,
/// unread counters, message updates) normally force SwiftUI to re-evaluate the
/// ForEach closure for EVERY visible row, which rebuilds preview strings and
/// dates again and again. This store rebuilds the whole row dictionary at most
/// once per 80 ms, so a burst of store ticks costs one formatting pass instead
/// of N passes per row.
@MainActor
final class ChatListPresentationStore: ObservableObject {
    static let shared = ChatListPresentationStore()

    @Published private(set) var rows: [Int64: ChatRowPresentation] = [:]
    private let debouncer = AdaptiveDebouncer()

    /// `make` builds one row's POD view-model; it is called once per displayed
    /// id per debounce window, not on every parent re-render. The window is
    /// taken from AdaptiveDebounceProvider at scheduling time, so thermal
    /// changes apply immediately without reconfiguring a fixed operator.
    func schedule(ids: [Int64], make: @escaping (Int64) -> ChatRowPresentation?) {
        guard !ids.isEmpty else { return }
        debouncer.schedule { [weak self] in
            guard let self else { return }
            var built: [Int64: ChatRowPresentation] = [:]
            built.reserveCapacity(ids.count)
            for id in ids {
                if let presentation = make(id) {
                    built[id] = presentation
                }
            }
            self.rows = built
            DiagnosticsLog.log("presentation.built rows=\(built.count)")
        }
    }

    func flush() {
        debouncer.cancelAll()
    }
}
