import Foundation

var failures = 0
func check(_ condition: Bool, _ name: String) {
    print((condition ? "PASS" : "FAIL") + " - " + name)
    if !condition { failures += 1 }
}

// --- ProxyAESCTR (MTProto obfuscation) ---
let key = [UInt8](repeating: 0x11, count: 32)
let iv = [UInt8](repeating: 0x22, count: 16)
let plain = Data((0..<256).map { UInt8($0 & 0xff) })
do {
    let cipher = ProxyAESCTR(key: key, iv: iv)
    let encrypted = cipher.process(plain)
    let decryptor = ProxyAESCTR(key: key, iv: iv)
    let decrypted = decryptor.process(encrypted)
    check(encrypted != plain, "AES-CTR encrypts")
    check(decrypted == plain, "AES-CTR round-trip")
    let cipher2 = ProxyAESCTR(key: key, iv: iv)
    check(cipher2.process(plain) == encrypted, "AES-CTR deterministic keystream")
}

// --- AdaptiveDebounceProvider (thread-safe interval source) ---
do {
    let provider = AdaptiveDebounceProvider.shared
    provider.update(0.25)
    check(abs(provider.current - 0.25) < 0.0001, "AdaptiveDebounceProvider stores interval")
    // Concurrent reads must always see a consistent value.
    let group = DispatchGroup()
    var sawInconsistent = false
    for _ in 0..<200 {
        group.enter()
        DispatchQueue.global().async {
            let v = provider.current
            if v != 0.25 && v != 0.08 { sawInconsistent = true }
            group.leave()
        }
    }
    DispatchQueue.global().async { provider.update(0.08) }
    group.wait()
    check(!sawInconsistent, "AdaptiveDebounceProvider reads are consistent under contention")
    provider.update(0.08)
}

// --- DevicePerformance ---
check(DevicePerformance.isLowMemory == (ProcessInfo.processInfo.physicalMemory <= 3 * 1024 * 1024 * 1024),
      "DevicePerformance threshold is consistent")

// --- MainActor singletons ---
let done = DispatchSemaphore(value: 0)
Task { @MainActor in
    // SearchHistory: limit and dedupe
    let history = SearchHistory.shared
    history.clear()
    for i in 0..<40 { history.record("query \(i)") }
    check(history.items.count <= 25, "SearchHistory capped at 25")
    history.record("query 39")
    check(history.items.first == "query 39", "SearchHistory dedupes and reorders")
    history.remove("query 39")
    check(!history.items.contains("query 39"), "SearchHistory remove")

    // DraftStore
    let drafts = DraftStore.shared
    drafts.save("  ", for: 777)
    check(drafts.draft(for: 777).isEmpty, "DraftStore drops blank drafts")
    drafts.save("hello", for: 777)
    check(drafts.draft(for: 777) == "hello", "DraftStore saves")
    drafts.clear(for: 777)
    check(drafts.draft(for: 777).isEmpty, "DraftStore clears")

    // LocalAliases
    let aliases = LocalAliases.shared
    aliases.setChatAlias("Team", chatId: 1)
    check(aliases.chatAlias(1) == "Team", "LocalAliases chat alias")
    aliases.setChatAlias("   ", chatId: 1)
    check(aliases.chatAlias(1) == nil, "LocalAliases removes empty alias")
    aliases.setUserAlias("Admin", userId: 2)
    check(aliases.userAlias(2) == "Admin", "LocalAliases user alias")

    // ChatVisitHistory
    let visits = ChatVisitHistory.shared
    visits.clear()
    visits.record(chatId: 10)
    visits.record(chatId: 20)
    visits.record(chatId: 10)
    check(visits.visits.contains { $0.chatId == 10 && $0.visits == 2 }, "ChatVisitHistory counts visits")

    done.signal()
}
while done.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
