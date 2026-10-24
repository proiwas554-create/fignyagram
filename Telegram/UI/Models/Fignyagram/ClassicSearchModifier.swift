import SwiftUI

struct ClassicSearchModifier: ViewModifier {
    let classic: Bool
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if classic {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(prompt, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                content
            }
        } else {
            content.searchable(text: $text, prompt: prompt)
        }
    }
}
