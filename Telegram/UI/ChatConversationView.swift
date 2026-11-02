import SwiftUI
import Combine
import TDLibKit
import UIKit

// MARK: - Selection model

/// Shared state for the message multi-selection (edit) mode. Owned by
/// `ChatConversationView`, observed by the message list and the action bar.
@MainActor
final class MessageSelectionModel: ObservableObject {
    let chatId: Int64

    @Published private(set) var isEditing = false
    @Published private(set) var selected: Set<Int64> = []

    /// Set by `ChatView`: shows the legacy single-message actions sheet for a
    /// message that is currently selected.
    var onShowActions: ((Int64) -> Void)?

    init(chatId: Int64) {
        self.chatId = chatId
    }

    var isEmpty: Bool { selected.isEmpty }

    func begin(with messageId: Int64? = nil) {
        if !isEditing {
            isEditing = true
        }
        if let messageId {
            selected = [messageId]
        }
    }

    func end() {
        isEditing = false
        selected.removeAll()
    }

    func toggle(_ messageId: Int64) {
        if selected.contains(messageId) {
            selected.remove(messageId)
        } else {
            selected.insert(messageId)
        }
    }

    func contains(_ messageId: Int64) -> Bool {
        selected.contains(messageId)
    }
}

// MARK: - Row chrome

/// Wraps a message row and slides the native Telegram-style circular checkbox in
/// while edit mode is active.
struct MessageSelectionRow<Content: View>: View {
    @ObservedObject var model: MessageSelectionModel
    let messageId: Int64
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if model.isEditing {
                Button {
                    model.toggle(messageId)
                } label: {
                    Image(systemName: model.contains(messageId) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21, weight: .regular))
                        .foregroundColor(model.contains(messageId) ? .accentColor : .secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .padding(.top, 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .accessibilityLabel(model.contains(messageId) ? "Снять выбор" : "Выбрать сообщение")
            }
            content
        }
        .animation(.easeInOut(duration: 0.2), value: model.isEditing)
    }
}

// MARK: - Conversation screen

/// Detail-pane conversation: the existing `ChatView` plus the multi-selection
/// action bar that slides up from the bottom.
struct ChatConversationView: View {
    let chat: ChatTarget

    @StateObject private var selection: MessageSelectionModel

    init(chat: ChatTarget) {
        self.chat = chat
        _selection = StateObject(wrappedValue: MessageSelectionModel(chatId: chat.chatId))
    }

    var body: some View {
        ChatView(chatId: chat.chatId, focusMessageId: chat.messageId, selection: selection)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selection.isEditing {
                    MessageSelectionBar(model: selection)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: selection.isEditing)
    }
}

// MARK: - Bottom action bar

struct MessageSelectionBar: View {
    @ObservedObject var model: MessageSelectionModel
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var store = ChatStore.shared

    @State private var showForwardPicker = false
    @State private var confirmDelete = false

    private var selectedMessages: [TDLibKit.Message] {
        let all = store.messages[model.chatId] ?? []
        return all.filter { model.selected.contains($0.id) }
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        HStack(spacing: 22) {
            Button("Готово") { model.end() }
                .font(.appFootnote)

            Spacer()

            actionButton("Переслать", systemImage: "arrowshape.turn.up.right", enabled: !model.isEmpty) {
                showForwardPicker = true
            }
            actionButton("Копировать", systemImage: "doc.on.doc", enabled: !model.isEmpty) {
                copySelected()
            }
            actionButton("Удалить", systemImage: "trash", enabled: !model.isEmpty, destructive: true) {
                confirmDelete = true
            }
            if model.selected.count == 1, let id = model.selected.first {
                actionButton("Действия", systemImage: "ellipsis.circle", enabled: true) {
                    model.onShowActions?(id)
                }
            }

            Spacer()

            Text("\(model.selected.count)")
                .font(.appFootnote)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .sheet(isPresented: $showForwardPicker) {
            ChatPickerView(title: "Переслать в…") { target in
                forwardSelected(to: target)
            }
        }
        .confirmationDialog("Удалить выбранные сообщения?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { deleteSelected() }
            Button("Отмена", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func actionButton(_ title: String, systemImage: String, enabled: Bool,
                              destructive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.appCaption2)
            }
            .foregroundColor(destructive ? .red : (enabled ? .accentColor : .secondary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Actions

    private func copySelected() {
        let text = selectedMessages
            .map { MessageFormatter.preview($0.content) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        // UIPasteboard is the only pasteboard API available to Catalyst apps and
        // it is bridged to the macOS pasteboard by the system.
        UIPasteboard.general.string = text
    }

    private func forwardSelected(to target: Int64) {
        for message in selectedMessages {
            client.forward(message, to: target)
        }
        model.end()
    }

    private func deleteSelected() {
        let ids = Array(model.selected)
        guard !ids.isEmpty else { return }
        client.deleteMessages(chatId: model.chatId, ids: ids, forAll: false)
        model.end()
    }
}
