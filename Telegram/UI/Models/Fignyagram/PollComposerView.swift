import SwiftUI

struct PollComposerView: View {
    let onSend: (String, [String], Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var anonymous = true
    @State private var multiple = false

    private var cleanOptions: [String] {
        options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        cleanOptions.count >= 2
    }

    var body: some View {
        NavigationView {
            Form {
                Section(L10n.t("Auto.091100c8e6")) {
                    TextField(L10n.t("Auto.9c0c211a0f"), text: $question)
                        .lineLimit(3)
                }

                Section(L10n.t("Auto.c28cdf2fb3")) {
                    ForEach(options.indices, id: \.self) { index in
                        HStack {
                            TextField("Вариант \(index + 1)", text: $options[index])
                            if options.count > 2 {
                                Button {
                                    options.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if options.count < 10 {
                        Button {
                            options.append("")
                        } label: {
                            Label(L10n.t("Auto.76be6bc4d7"), systemImage: "plus.circle")
                        }
                    }
                }

                Section {
                    Toggle(L10n.t("Auto.bf89d511d1"), isOn: $anonymous)
                    Toggle(L10n.t("Auto.628a258108"), isOn: $multiple)
                } footer: {
                    Text(L10n.t("Auto.63bd5a2f79"))
                        .font(.appFootnote)
                }
            }
            .navigationTitle(L10n.t("Auto.05c8ff5150"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Common.Send")) {
                        onSend(
                            question.trimmingCharacters(in: .whitespacesAndNewlines),
                            cleanOptions,
                            anonymous,
                            multiple
                        )
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
