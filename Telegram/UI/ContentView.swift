import SwiftUI

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

    var body: some View {
        Group {
            if client.isAuthorized {
                Group {
                    if classic.isEnabled {
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
        .font(fonts.bodyFont)
        .environment(\.locale, translation.appLocale)
        .onAppear {
            DiagnosticsLog.log("ContentView.onAppear")
            MainThreadWatchdog.shared.start()
            GPUOptimization.shared.start()
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
