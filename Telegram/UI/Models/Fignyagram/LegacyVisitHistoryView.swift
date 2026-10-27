import SwiftUI

struct LegacyVisitHistoryView: View {
    @ObservedObject private var history = ChatVisitHistory.shared
    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dismiss) private var dismiss
    var onOpen: (Int64) -> Void

    var body: some View {
        NavigationView {
            List(history.visits) { visit in
                Button {
                    onOpen(visit.chatId)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.chats[visit.chatId]?.title ?? "Чат \(visit.chatId)")
                            Text(visit.lastVisited, style: .date)
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(visit.visits)×").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("История заходов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
