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
                Section("Вопрос") {
                    TextField("Задайте вопрос", text: $question)
                        .lineLimit(3)
                }

                Section("Варианты ответа") {
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
                            Label("Добавить вариант", systemImage: "plus.circle")
                        }
                    }
                }

                Section {
                    Toggle("Анонимный опрос", isOn: $anonymous)
                    Toggle("Несколько ответов", isOn: $multiple)
                } footer: {
                    Text("Анонимный опрос не показывает, кто как проголосовал. Несколькими ответами можно выбрать несколько вариантов.")
                        .font(.appFootnote)
                }
            }
            .navigationTitle("Новый опрос")
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
