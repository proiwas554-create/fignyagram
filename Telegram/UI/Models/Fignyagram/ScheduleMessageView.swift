import SwiftUI

struct ScheduleMessageView: View {
    @Binding var text: String
    let onSchedule: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Auto.bbb9de7a3d")) {
                    DatePicker(L10n.t("Auto.b64c7c6e62"),
                        selection: $date,
                        in: Date().addingTimeInterval(60)...Date().addingTimeInterval(366 * 86400),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    HStack {
                        Button(L10n.t("Auto.d1cfef3638")) {
                            date = Date().addingTimeInterval(3600)
                        }
                        Button(L10n.t("Auto.d102341998")) {
                            date = Date().addingTimeInterval(86400)
                        }
                    }
                    .font(.appFootnote)
                }

                Section(L10n.t("Common.Message")) {
                    Text(text)
                        .lineLimit(4)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.t("Auto.ed61a83aab"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Auto.5473e18b3b")) {
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
