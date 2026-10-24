import SwiftUI

/// Recent global-search queries. Available in both design modes via the clock
/// button in the chat list header.
struct SearchHistoryView: View {
    @ObservedObject private var history = SearchHistory.shared
    @Environment(\.dismiss) private var dismiss
    var onPick: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                if history.items.isEmpty {
                    Text("История поиска пуста")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(history.items, id: \.self) { item in
                        Button {
                            onPick(item)
                            dismiss()
                        } label: {
                            Label(item, systemImage: "clock.arrow.circlepath")
                                .foregroundColor(.primary)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            history.remove(history.items[index])
                        }
                    }
                }
            }
            .navigationTitle("История поиска")
            .modifier(GlassListModifier())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !history.items.isEmpty {
                        Button("Очистить", role: .destructive) { history.clear() }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
