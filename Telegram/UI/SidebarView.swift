import SwiftUI
import TDLibKit

/// Left column of the Duo shell: content tabs, the original mobile settings
/// screen and the developer hub entry point.
struct SidebarView: View {
    @Binding var currentTab: DuoTab
    let onOpenDeveloper: () -> Void

    @ObservedObject private var developer = DeveloperMode.shared
    @ObservedObject private var client = TelegramClient.shared

    @State private var showSettings = false

    var body: some View {
        List {
            Section {
                ForEach(DuoTab.allCases) { tab in
                    Button {
                        currentTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.icon)
                            .font(.system(size: 13, weight: currentTab == tab ? .semibold : .regular))
                            .foregroundColor(currentTab == tab ? .accentColor : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        currentTab == tab ? Color.accentColor.opacity(0.12) : Color.clear
                    )
                }
            } header: {
                Text("FIGNYAGRAM")
            }

            Section {
                Button {
                    showSettings = true
                } label: {
                    Label("Настройки", systemImage: "gearshape")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("ПРОФИЛЬ")
            }

            Section {
                Button {
                    onOpenDeveloper()
                } label: {
                    Label("Разработчик", systemImage: "hammer")
                }
                .buttonStyle(.plain)
                .foregroundColor(developer.isUnlocked ? .accentColor : .secondary)
            } header: {
                Text("ОТЛАДКА")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Fignyagram")
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    onOpenDeveloper()
                } label: {
                    Label("Настройки разработчика", systemImage: "gearshape.2")
                        .font(.appFootnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(developer.isUnlocked ? .accentColor : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                accountFooter
            }
        }
    }

    @ViewBuilder
    private var accountFooter: some View {
        if let me = client.me {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(me.firstName.isEmpty ? "Аккаунт" : me.firstName)
                        .font(.appFootnote)
                        .lineLimit(1)
                    if let username = me.usernames?.activeUsernames.first, !username.isEmpty {
                        Text("@\(username)")
                            .font(.appCaption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
