import SwiftUI
import TDLibKit

/// Telegram Stars gifts for a user or channel.
struct GiftsView: View {
    let owner: MessageSender
    let title: String

    @ObservedObject private var client = TelegramClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var gifts: [AvailableGift] = []
    @State private var isLoading = true
    @State private var sending = false
    @State private var confirmGift: AvailableGift?
    @State private var message: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView(NSLocalizedString("Generated.6a3c63dc3960", comment: ""))
                } else if gifts.isEmpty {
                    Text(L10n.t("Auto.496cd76e53")).foregroundColor(.secondary)
                } else {
                    List(gifts, id: \.gift.id) { item in
                        HStack(spacing: 12) {
                            Text(item.gift.sticker.emoji.isEmpty ? "🎁" : item.gift.sticker.emoji)
                                .font(.system(size: 34))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title.isEmpty ? (item.gift.sticker.emoji + NSLocalizedString("Generated.ce8193f35f3f", comment: "")) : item.title)
                                    .font(.subheadline.bold())
                                Text("\(item.gift.starCount) ⭐")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(L10n.t("Common.Send")) { confirmGift = item }
                                .buttonStyle(.bordered)
                                .disabled(sending)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("Auto.90300526d0"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .confirmationDialog(L10n.t("Auto.cdf2c569df"),
                isPresented: Binding(get: { confirmGift != nil }, set: { if !$0 { confirmGift = nil } }),
                titleVisibility: .visible
            ) {
                if let gift = confirmGift {
                    Button(String(format: L10n.t("AutoI.d253ba767e"), String(describing: gift.gift.starCount))) { send(gift) }
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) { confirmGift = nil }
            } message: {
                Text(String(format: L10n.t("AutoI.9c76e03101"), String(describing: title)))
            }
            .alert(L10n.t("Auto.c484149947"), isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .task {
                gifts = await client.availableGifts()
                isLoading = false
            }
        }
        .navigationViewStyle(.stack)
    }

    private func send(_ item: AvailableGift) {
        sending = true
        confirmGift = nil
        Task {
            defer { sending = false }
            do {
                try await client.sendGift(item.gift, to: owner)
                message = NSLocalizedString("Generated.8fe29112c016", comment: "")
            } catch {
                message = TelegramClient.describe(error)
            }
        }
    }
}
