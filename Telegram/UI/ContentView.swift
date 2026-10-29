import SwiftUI
import TDLibKit

struct ContentView: View {
    @ObservedObject private var client = TelegramClient.shared
    @State private var selectedTab = 0
    @AppStorage("showMusicTab") private var showMusicTab = true
    @AppStorage("showNewsTab") private var showNewsTab = false
    @State private var secretChatTaps = 0
    @State private var showDeveloper = false
    @AppStorage("showFPS") private var showFPS = false
    @ObservedObject private var chatPresentation = ChatPresentationState.shared
    @ObservedObject private var ultra = UltraMode.shared
    @ObservedObject private var classic = ClassicDesignMode.shared
    @ObservedObject private var fonts = FontManager.shared
    @ObservedObject private var shareInbox = ShareInbox.shared
    @ObservedObject private var translation = TranslationService.shared
    @ObservedObject private var appLock = AppLock.shared
    @ObservedObject private var calls = CallManager.shared

    var body: some View {
        let _ = CrashTrace.step("content body authorized=\(client.isAuthorized)")
        Group {
            if client.isAuthorized {
                Group {
                    if classic.isEnabled {
                        classicRoot
                    } else if #available(iOS 16.0, *) {
                        modernRoot
                    } else {
                        MainRootView()
                    }
                }
                .overlay {
                    if showFPS {
                        FPSOverlayView()
                    }
                }
                .sheet(isPresented: $showDeveloper) {
                    DeveloperSettingsView()
                }
                .sheet(item: $shareInbox.payload, onDismiss: {
                    ShareInbox.shared.handleDismiss()
                }) { payload in
                    ShareComposerView(payload: payload)
                }
            } else {
                AuthView()
            }
        }
        .overlay {
            if calls.currentCall != nil && calls.currentCall?.isVideo != true {
                CallView()
            } else {
                GroupCallOverlay()
            }
            if appLock.isEnabled && appLock.isLocked {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill").font(.system(size: 44))
                    Text(L10n.t("Auto.3c8b3d7f53")).font(.headline)
                    Button(L10n.t("Auto.e3d4814785")) { Task { await appLock.unlock() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .ignoresSafeArea()
                .task {
                    // Ask for Face ID / Touch ID immediately instead of waiting
                    // for the button tap.
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await appLock.unlock()
                }
            }
        }
        .font(fonts.bodyFont)
        .environment(\.locale, translation.appLocale)
        .environment(\.openURL, OpenURLAction { url in
            if DeepLinkRouter.shared.handle(url) { return .handled }
            return .systemAction
        })
        .onAppear {
            CrashLogger.install()
            CallDiag.log("app started engineAvailable=\(VoIPBridge.engineAvailable()) framework=\(Bundle.main.privateFrameworksURL?.appendingPathComponent("TgVoipWebrtc.framework").path ?? "n/a")")
            DiagnosticsLog.log("ContentView.onAppear")
            ScreenProtection.shared.apply()
            MainThreadWatchdog.shared.start()
            // Verify which image owns the WebRTC Objective-C classes: the
            // engine and LiveKit both define them and the runtime keeps the
            // first registration.
            for name in ["RTCAudioSession", "RTCVideoCodecInfo"] {
                if let cls = NSClassFromString(name) {
                    let audio4 = class_getInstanceMethod(cls, NSSelectorFromString("setConfiguration:active:error:disableRecording:")) != nil
                    let native = class_getInstanceMethod(cls, NSSelectorFromString("nativeSdpVideoFormat")) != nil
                    let image = class_getImageName(cls).map { String(cString: $0) } ?? "?"
                    CallDiag.log("class \(name) audio4=\(audio4) nativeSdp=\(native) image=\(image)")
                } else {
                    CallDiag.log("class \(name) NOT FOUND")
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                CallDiag.log("tdlib log tap messages=\(tdLogTapSeenCount())")
            }
            GPUOptimization.shared.start()
            if DevicePerformance.isLowMemory {
                ImageCache.applyLegacyDeviceTuning()
                HardwareThermalController.shared.apply()
            }
            TranslationService.shared.applySystemLanguageDefaultsIfNeeded()
            AccountStore.cleanupOrphanDatabases()
            ShareInbox.shared.loadPending()
            client.start()
            // Lazy proxy start: wait until the first frame is on screen so the
            // NWListener on 1443 cannot race with iOS window/XPC bootstrap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                BuiltInProxyManager.shared.applyIfEnabled()
            }
        }
    }

    /// Legacy devices: only one screen exists at a time (no ZStack with two
    /// NavigationViews / searchable controllers), which crashed iOS 15.
    private var legacyRoot: some View {
        MainRootView()
    }

    /// Original flagship root (iOS 16+): native TabView and its look.
    private var modernRoot: some View {
        TabView(selection: $selectedTab) {
            ChatListView()
                .tag(0)
                .tabItem { Label(L10n.t("Auto.19adecc3d1"), systemImage: "bubble.left.and.bubble.right") }
            if showMusicTab {
                MusicView()
                    .tag(1)
                    .tabItem { Label(L10n.t("Auto.0660a7580a"), systemImage: "music.note") }
            }
            if showNewsTab {
                NewsFeedView()
                    .tag(2)
                    .tabItem { Label(L10n.t("Auto.69df1f85b0"), systemImage: "newspaper") }
            }
        }
    }

    private var classicRoot: some View {
        ZStack {
            ChatListView()
                .opacity(selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(selectedTab == 0)
            MusicView()
                .opacity(selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(selectedTab == 1)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !chatPresentation.isChatOpen {
                HStack(spacing: 0) {
                    Button {
                        if selectedTab == 0 {
                            secretChatTaps += 1
                            if secretChatTaps >= 10 {
                                secretChatTaps = 0
                                DeveloperMode.shared.unlock()
                                showDeveloper = true
                            }
                        } else {
                            selectedTab = 0
                            secretChatTaps = 0
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 20))
                            Text(L10n.t("Auto.19adecc3d1")).font(.appCaption2)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundColor(selectedTab == 0 ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        selectedTab = 1
                        secretChatTaps = 0
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "music.note")
                                .font(.system(size: 20))
                            Text(L10n.t("Auto.0660a7580a")).font(.appCaption2)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundColor(selectedTab == 1 ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
                .background(
                    Color(.systemBackground)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .top) { Divider() }
                )
            }
        }
    }
}

#Preview {
    ContentView()
}


/// Crash-safe root for 2 GB devices: no native TabView (it crashed on iOS 15),
/// but the same screens and features as the modern root.
struct MainRootView: View {
    @State private var selectedTab = 0
    @State private var secretChatTaps = 0
    @State private var showDeveloper = false
    @AppStorage("showMusicTab") private var showMusicTab = true
    @AppStorage("showNewsTab") private var showNewsTab = false
    @ObservedObject private var chatPresentation = ChatPresentationState.shared

    var body: some View {
        Group {
            if selectedTab == 0 {
                ChatListView()
            } else if selectedTab == 1 {
                MusicView()
            } else {
                NewsFeedView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !chatPresentation.isChatOpen {
                HStack(spacing: 0) {
                    tabButton(index: 0, icon: "bubble.left.and.bubble.right.fill", title: L10n.t("Auto.19adecc3d1"))
                    if showMusicTab {
                        tabButton(index: 1, icon: "music.note", title: L10n.t("Auto.0660a7580a"))
                    }
                    if showNewsTab {
                        tabButton(index: 2, icon: "newspaper", title: L10n.t("Feed.Tab.Title"))
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
                .background(
                    Color(.systemBackground)
                        .ignoresSafeArea(edges: .bottom)
                        .overlay(alignment: .top) { Divider() }
                )
            }
        }
    }

    private func tabButton(index: Int, icon: String, title: String) -> some View {
        Button {
            if index == 0 {
                secretChatTaps += 1
                if secretChatTaps >= 10 {
                    secretChatTaps = 0
                    DeveloperMode.shared.unlock()
                    showDeveloper = true
                }
            }
            selectedTab = index
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.appCaption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(selectedTab == index ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}
