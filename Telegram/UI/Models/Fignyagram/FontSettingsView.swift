import SwiftUI

struct FontSettingsView: View {
    @ObservedObject private var fonts = FontManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            List {
                Section(L10n.t("Auto.719a59ad42")) {
                    ForEach(FontManager.Builtin.allCases) { font in
                        Button {
                            fonts.select(font.rawValue)
                        } label: {
                            HStack {
                                Text("Fignyagram").font(baseFont(font)).foregroundColor(.primary)
                                Spacer()
                                if fonts.selection == font.rawValue {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }

                if !fonts.customNames.isEmpty {
                    Section(L10n.t("Auto.ba5bf371c4")) {
                        ForEach(fonts.customNames, id: \.self) { name in
                            Button {
                                fonts.select(name)
                            } label: {
                                HStack {
                                    Text(name).font(.custom(name, size: 17)).foregroundColor(.primary)
                                    Spacer()
                                    if fonts.selection == name {
                                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .swipeActions {
                                Button(L10n.t("Common.Delete"), role: .destructive) { fonts.removeCustomFont(name) }
                            }
                        }
                    }
                }

                Section {
                    Button { showPicker = true } label: {
                        Label(L10n.t("Auto.1c10432344"), systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text(L10n.t("Auto.6af9a33acd"))
                        .font(.footnote)
                }

                if let errorText {
                    Text(errorText).foregroundColor(.red).font(.footnote)
                }
            }
            .navigationTitle(L10n.t("Auto.e479fdc532"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { urls in
                    guard let url = urls.first else { return }
                    do { try fonts.importFont(from: url) }
                    catch { errorText = error.localizedDescription }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func baseFont(_ builtin: FontManager.Builtin) -> Font {
        switch builtin {
        case .system: return .system(size: 17)
        case .rounded: return .system(size: 17, design: .rounded)
        case .serif: return .system(size: 17, design: .serif)
        case .monospaced: return .system(size: 17, design: .monospaced)
        }
    }
}
