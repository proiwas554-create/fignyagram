import SwiftUI
import TDLibKit

struct ContentView: View {
    @ObservedObject private var client = TelegramClient.shared
    @State private var selectedTab = 0
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
        Group {
            if client.isAuthorized {
                Group {
                    if DevicePerformance.isLowMemory && !classic.isEnabled {
                        legacyRoot
                    } else if classic.isEnabled {
                        // On 2 GB devices the custom root avoids the native
                        // TabView, which was crashing right after authorization
                        // on iOS 15 (app restarted immediately).
                        classicRoot
                    } else {
                        TabView(selection: $selectedTab) {
                            ChatListView()
                                .tag(0)
                                .tabItem { Label("Чаты", systemImage: "bubble.left.and.bubble.right") }
                            MusicView()
                                .tag(1)
                                .tabItem { Label("Музыка", systemImage: "music.note") }
                        }
                        .overlay(alignment: .bottom) {
                            if !chatPresentation.isChatOpen {
                            HStack(spacing: 0) {
                                Color.clear
                                    .frame(height: 49)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
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
                                    }
                                Color.clear.frame(height: 49)
                            }
                            .frame(height: 49)
                            }
                        }
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
                    Text("Fignyagram заблокирован").font(.headline)
                    Button("Разблокировать") { Task { await appLock.unlock() } }
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
        Group {
            if selectedTab == 0 {
                LegacyChatListView()
            } else {
                MusicView()
            }
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
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 20))
                            Text("Чаты").font(.appCaption2)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundColor(selectedTab == 0 ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button { selectedTab = 1 } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "music.note").font(.system(size: 20))
                            Text("Музыка").font(.appCaption2)
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
                            Text("Чаты").font(.appCaption2)
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
                            Text("Музыка").font(.appCaption2)
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
