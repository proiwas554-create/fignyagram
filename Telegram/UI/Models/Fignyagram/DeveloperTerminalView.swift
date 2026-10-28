import SwiftUI
import UIKit
import TDLibKit

struct DeveloperTerminalView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = TelegramClient.shared
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var performance = PerformanceMode.shared
    @ObservedObject private var proxy = BuiltInProxyManager.shared
    @ObservedObject private var store = ChatStore.shared
    @ObservedObject private var privacy = PrivacyPreferences.shared

    @State private var command = ""
    @State private var lines: [String] = ["Fignyagram terminal. Введите help."]
    @State private var history: [String] = []
    @State private var historyIndex: Int?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color.black)
                    .foregroundColor(.green)
                    .onChange(of: lines.count) { _ in
                        if let last = lines.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text("$")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)
                    TextField("command", text: $command)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(run)
                    Button("↑") {
                        guard !history.isEmpty else { return }
                        let next = min((historyIndex ?? history.count) - 1, history.count - 1)
                        historyIndex = max(next, 0)
                        command = history[historyIndex ?? 0]
                    }
                    .buttonStyle(.borderless)
                    Button("↓") {
                        guard !history.isEmpty else { return }
                        let next = min((historyIndex ?? 0) + 1, history.count - 1)
                        historyIndex = next
                        command = history[next]
                    }
                    .buttonStyle(.borderless)
                    Button("Run", action: run)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle(L10n.t("Auto.2069cc5c6b"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func run() {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cmd.isEmpty else { return }
        lines.append("$ \(cmd)")
        history.append(cmd)
        historyIndex = nil
        command = ""

        if cmd == "!!" {
            if let last = history.dropLast().last {
                command = last
                run()
            }
            return
        }

        if cmd.hasPrefix("/open_secret_chat_") {
            if let id = Int64(cmd.replacingOccurrences(of: "/open_secret_chat_", with: "")) {
                HiddenChats.shared.reveal(id)
                lines.append("chat \(id) revealed for this session")
            } else {
                lines.append("usage: /open_secret_chat_<id>")
            }
            return
        }
        if cmd.hasPrefix("/hide_secret_chat_") {
            if let id = Int64(cmd.replacingOccurrences(of: "/hide_secret_chat_", with: "")) {
                HiddenChats.shared.hide(id)
                lines.append("chat \(id) hidden")
            } else {
                lines.append("usage: /hide_secret_chat_<id>")
            }
            return
        }
        if cmd.hasPrefix("/unhide_secret_chat_") {
            if let id = Int64(cmd.replacingOccurrences(of: "/unhide_secret_chat_", with: "")) {
                HiddenChats.shared.unhide(id)
                lines.append("chat \(id) is visible again")
            } else {
                lines.append("usage: /unhide_secret_chat_<id>")
            }
            return
        }
        if cmd == "/hidden" {
            let ids = HiddenChats.shared.hiddenIds.sorted().map(String.init).joined(separator: ", ")
            lines.append(ids.isEmpty ? "no hidden chats" : "hidden: \(ids)")
            return
        }

        if cmd == "/guest" {
            GuestMode.shared.enter()
            lines.append("guest mode enabled; unlock with biometrics to return")
            return
        }
        if cmd == "/cachelimit" {
            let limit = UserDefaults.standard.integer(forKey: "autoCleanCacheLimitMB")
            lines.append(limit > 0 ? "auto clean limit=\(limit)MB" : "auto clean off")
            return
        }
        if cmd.hasPrefix("/cachelimit ") {
            let value = Int(cmd.replacingOccurrences(of: "/cachelimit ", with: "")) ?? 0
            UserDefaults.standard.set(max(0, value), forKey: "autoCleanCacheLimitMB")
            lines.append(value > 0 ? "auto clean limit set to \(value)MB" : "auto clean disabled")
            return
        }
        if cmd == "/macro_list" {
            if AutomationEngine.shared.rules.isEmpty {
                lines.append("no macros")
            } else {
                for (index, rule) in AutomationEngine.shared.rules.enumerated() {
                    let chat = rule.chatId.map(String.init) ?? "any"
                    lines.append("\(index): chat=\(chat) keyword=\(rule.keyword) -> \(rule.action.rawValue) \(rule.value)")
                }
            }
            return
        }
        if cmd == "/macro_clear" {
            AutomationEngine.shared.removeAll()
            lines.append("macros cleared")
            return
        }
        if cmd.hasPrefix("/macro_remove ") {
            if let index = Int(cmd.replacingOccurrences(of: "/macro_remove ", with: "")) {
                AutomationEngine.shared.removeRule(at: index)
                lines.append("macro removed")
            } else {
                lines.append("usage: /macro_remove <index>")
            }
            return
        }
        if cmd.hasPrefix("/macro_add ") {
            // /macro_add <chatId|any> <keyword> <action> [value...]
            let parts = cmd.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 4 {
                let chatPart = parts[1]
                let chatId: Int64? = chatPart == "any" ? nil : Int64(chatPart)
                let keyword = parts[2]
                if let action = AutomationEngine.Rule.Action(rawValue: parts[3]) {
                    let value = parts.dropFirst(4).joined(separator: " ")
                    if let rule = AutomationEngine.shared.addRule(chatId: chatId, keyword: keyword, action: action, value: value) {
                        lines.append("macro added: \(rule.keyword) -> \(action.rawValue)")
                    }
                } else {
                    lines.append("actions: " + AutomationEngine.Rule.Action.allCases.map(\.rawValue).joined(separator: "|"))
                }
            } else {
                lines.append("usage: /macro_add <chatId|any> <keyword> <action> [value]")
            }
            return
        }
        if cmd == "/viewonce_list" {
            let keys = ViewOnceStore.shared.saved.keys.sorted()
            lines.append(keys.isEmpty ? "no preserved media" : keys.joined(separator: ", "))
            return
        }
        if cmd == "/viewonce_clear" {
            ViewOnceStore.shared.clearAll()
            lines.append("preserved media cleared")
            return
        }

        switch cmd {
        case "help", "?":
            lines.append("help status cache clear messages proxy notify optimize deleted chats account version echo")
            lines.append("/hidden | /open_secret_chat_<id> | /hide_secret_chat_<id> | /unhide_secret_chat_<id>")
            lines.append("/macro_add <chatId|any> <keyword> <action> [value] | /macro_list | /macro_remove <i> | /macro_clear")
            lines.append("/viewonce_list | /viewonce_clear | /cachelimit <MB>")
            lines.append("proxy on|off | optimize on|off | notify on|off | deleted on|off | log 0...5")
        case "status":
            lines.append("account=\(client.me?.id ?? 0) chats=\(store.chats.count) cache=\(MessageFormatter.fileSize(cache.totalBytes))")
            lines.append("proxy=\(proxy.status) health=\(proxy.health)")
        case "account":
            lines.append("id=\(client.me?.id ?? 0) name=\(client.me.map { [$0.firstName, $0.lastName].filter { !$0.isEmpty }.joined(separator: " ") } ?? "—")")
        case "version":
            lines.append("Fignyagram \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") / iOS \(UIDevice.current.systemVersion)")
        case "cache":
            lines.append("cache bytes=\(cache.totalBytes) categories=\(cache.categories.count)")
        case "clear":
            cache.clearAll()
            lines.append("cache clear requested")
        case "messages":
            store.clearLoadedMessages()
            lines.append("loaded message cache cleared")
        case "proxy":
            lines.append("enabled=\(proxy.isEnabled) running=\(proxy.isRunning) status=\(proxy.status)")
        case "optimize":
            lines.append("optimization=\(performance.isEnabled) level=\(performance.level.title)")
        case "notify":
            lines.append("notifications=\(UserDefaults.standard.bool(forKey: "notificationsDisabled") ? "off" : "on")")
        case "deleted":
            lines.append("deleted=\(privacy.keepDeletedMessages ? "shown" : "hidden")")
        case "chats":
            lines.append("chats=\(store.chats.count) users=\(store.users.count)")
        default:
            if cmd.hasPrefix("echo ") {
                lines.append(String(cmd.dropFirst(5)))
            } else if cmd.hasPrefix("log ") {
                if let level = Int(cmd.dropFirst(4)), (0...5).contains(level) {
                    client.setLogVerbosity(level)
                    lines.append("log level = \(level)")
                } else {
                    lines.append("usage: log 0...5")
                }
            } else if cmd == "proxy on" || cmd == "proxy off" {
                proxy.setEnabled(cmd == "proxy on")
                lines.append("proxy \(cmd == "proxy on" ? "enabled" : "disabled")")
            } else if cmd == "optimize on" || cmd == "optimize off" {
                performance.isEnabled = cmd == "optimize on"
                lines.append("optimization \(performance.isEnabled ? "on" : "off")")
            } else if cmd == "notify on" || cmd == "notify off" {
                UserDefaults.standard.set(cmd == "notify off", forKey: "notificationsDisabled")
                lines.append("notifications \(cmd == "notify off" ? "off" : "on")")
            } else if cmd == "deleted on" || cmd == "deleted off" {
                privacy.keepDeletedMessages = cmd == "deleted on"
                lines.append("deleted \(privacy.keepDeletedMessages ? "shown" : "hidden")")
            } else {
                lines.append("unknown command")
            }
        }
    }
}
