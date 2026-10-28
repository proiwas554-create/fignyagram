import SwiftUI
import UIKit

struct QuoteSelectionView: View {
    let text: String
    let onQuote: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedText = ""
    @State private var selectedPosition = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                SelectableTextView(
                    text: text,
                    selectedText: $selectedText,
                    selectedPosition: $selectedPosition
                )
                .padding(12)

                if selectedText.isEmpty {
                    Text("Выделите часть текста, чтобы процитировать её")
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 10)
                }
            }
            .navigationTitle("Цитировать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Цитировать") {
                        onQuote(selectedText, selectedPosition)
                        dismiss()
                    }
                    .disabled(selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String
    @Binding var selectedText: String
    @Binding var selectedPosition: Int

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.text = text
        view.font = UIFont.systemFont(ofSize: 18)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .systemBackground
        view.delegate = context.coordinator
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextView
        init(_ parent: SelectableTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let range = textView.selectedTextRange else { return }
            let selected = textView.text(in: range) ?? ""
            let position = textView.offset(from: textView.beginningOfDocument, to: range.start)
            parent.selectedText = selected
            parent.selectedPosition = position
        }
    }
}
