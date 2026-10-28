import Combine
import CryptoKit
import Foundation
import SwiftUI

/// AES-256-GCM encrypted text notes sent as tiny files. The key never leaves
/// the devices: it is hashed to 32 bytes and the ciphertext carries the nonce.
nonisolated enum CryptoNotes {
    static let header = "FIGNYAENC1:"

    static func encrypt(_ text: String, passphrase: String) throws -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data(passphrase.utf8)))
        let sealed = try AES.GCM.seal(Data(text.utf8), using: key)
        guard let combined = sealed.combined else { throw CryptoError.encoding }
        return header + combined.base64EncodedString()
    }

    static func decrypt(_ payload: String, passphrase: String) throws -> String {
        let base64 = payload.hasPrefix(header) ? String(payload.dropFirst(header.count)) : payload
        guard let data = Data(base64Encoded: base64) else { throw CryptoError.format }
        let key = SymmetricKey(data: SHA256.hash(data: Data(passphrase.utf8)))
        let box = try AES.GCM.SealedBox(combined: data)
        let opened = try AES.GCM.open(box, using: key)
        guard let text = String(data: opened, encoding: .utf8) else { throw CryptoError.encoding }
        return text
    }

    enum CryptoError: Error { case format, encoding }
}

/// Local quick-reply templates, inserted into the composer on long press.
@MainActor
final class SnippetsStore: ObservableObject {
    static let shared = SnippetsStore()
    @Published private(set) var snippets: [String] = []
    private static let key = "composerSnippets"

    private init() {
        snippets = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !snippets.contains(trimmed) else { return }
        snippets.append(trimmed)
        persist()
    }

    func remove(_ text: String) {
        snippets.removeAll { $0 == text }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(snippets, forKey: Self.key)
    }
}

/// Passphrase prompt used for encrypting and decrypting notes.
struct PassphrasePrompt: View {
    let title: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationView {
            Form {
                Section(title) {
                    SecureField("Ключ", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("Ключ не передаётся на сервер: им шифруется текст на этом устройстве.")
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Зашифрованная заметка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        let key = value
                        dismiss()
                        onSubmit(key)
                    }
                    .disabled(value.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}


/// Manage quick-reply templates.
struct SnippetsSettingsView: View {
    @ObservedObject private var store = SnippetsStore.shared
    @State private var draft = ""

    var body: some View {
        Form {
            Section("Новый шаблон") {
                TextField("Текст быстрого ответа", text: $draft)
                Button("Добавить") {
                    store.add(draft)
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Шаблоны") {
                if store.snippets.isEmpty {
                    Text("Пока нет шаблонов").foregroundColor(.secondary)
                }
                ForEach(store.snippets, id: \.self) { snippet in
                    Text(snippet)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.remove(snippet)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                }
            }
            Section {
                Text("Шаблоны доступны по долгому нажатию на поле ввода.")
                    .font(.appFootnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Быстрые шаблоны")
        .navigationBarTitleDisplayMode(.inline)
    }
}
