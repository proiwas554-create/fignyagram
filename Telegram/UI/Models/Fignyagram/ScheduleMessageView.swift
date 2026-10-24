import SwiftUI

struct ScheduleMessageView: View {
    @Binding var text: String
    let onSchedule: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationView {
            Form {
                Section("Когда отправить") {
                    DatePicker(
                        "Дата и время",
                        selection: $date,
                        in: Date().addingTimeInterval(60)...Date().addingTimeInterval(366 * 86400),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    HStack {
                        Button("Через час") {
                            date = Date().addingTimeInterval(3600)
                        }
                        Button("Завтра") {
                            date = Date().addingTimeInterval(86400)
                        }
                    }
                    .font(.appFootnote)
                }

                Section("Сообщение") {
                    Text(text)
                        .lineLimit(4)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Отложенное сообщение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запланировать") {
                        onSchedule(date)
                        dismiss()
                    }
                    .disabled(date <= Date())
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
