import SwiftUI

/// Deliberately flat and cheap: no shadows, no materials, no blurs.
struct WatchChatRowView: View {
    let chat: WatchChat

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .overlay(
                    Text(String(chat.title.prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .semibold))
                )
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if chat.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 9))
                    }
                    Text(chat.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill").font(.system(size: 9))
                    }
                }
                Text(chat.preview)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if chat.unread > 0 {
                Text("\(chat.unread)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
            }
        }
    }
}
