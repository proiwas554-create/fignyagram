import SwiftUI

struct ContentView: View {
    @StateObject private var client = TelegramClient.shared
    @StateObject private var store = ChatStore.shared

    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var messageText = ""

    var body: some View {
        NavigationView {
            Group {
                if !client.isAuthorized {
                    authView
                } else {
                    chatListView
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            client.start()
        }
    }

    private var authView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("🦋").font(.system(size: 80))
            Text("Fignyagram")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("ультралёгкий клиент Telegram").font(.caption).foregroundColor(.secondary)
            Spacer().frame(height: 20)
            
            Text(client.authState).font(.headline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)

            if client.authState.contains("номер") {
                TextField("+7XXXXXXXXXX", text: $phone).textFieldStyle(.roundedBorder).keyboardType(.phonePad).padding(.horizontal)
                Button("Отправить номер") { client.sendPhoneNumber(phone) }.buttonStyle(.borderedProminent)
            }

            if client.authState.contains("код") {
                TextField("Код из Telegram", text: $code).textFieldStyle(.roundedBorder).keyboardType(.numberPad).padding(.horizontal)
                Button("Подтвердить") { client.sendCode(code) }.buttonStyle(.borderedProminent)
            }

            if client.authState.contains("пароль") {
                SecureField("Пароль 2FA", text: $password).textFieldStyle(.roundedBorder).padding(.horizontal)
                Button("Войти") { client.sendPassword(password) }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.padding()
    }

    private var chatListView: some View {
        Group {
            if store.chats.isEmpty {
                VStack(spacing: 16) {
                    Text("🦋").font(.system(size: 60)).opacity(0.6)
                    Text("Чатов пока нет").foregroundColor(.secondary)
                    Button("Загрузить чаты") { client.loadChats() }.buttonStyle(.bordered)
                }
            } else {
                List {
                    ForEach(Array(store.chats.keys).sorted(), id: \.self) { chatId in
                        NavigationLink {
                            chatDetailView(chatId: chatId)
                        } label: {
                            Text(store.chats[chatId] ?? "Чат \(chatId)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Fignyagram")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Обновить") { client.loadChats() }
            }
        }
    }

    private func chatDetailView(chatId: Int64) -> some View {
        VStack(spacing: 0) {
            if store.loadingChats.contains(chatId) {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Загрузка...").foregroundColor(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                
            } else if let msgs = store.messages[chatId], !msgs.isEmpty {
                List(msgs, id: \.self) { msg in
                    Text(msg).frame(maxWidth: .infinity, alignment: .leading)
                }.listStyle(.plain)
                
            } else {
                VStack(spacing: 12) {
                    Text("Сообщений нет").foregroundColor(.secondary)
                    Button("Обновить историю") {
                        client.loadHistory(chatId: chatId, forceReload: true)
                    }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                TextField("Сообщение...", text: $messageText).textFieldStyle(.roundedBorder)
                Button {
                    client.sendMessage(chatId: chatId, text: messageText)
                    messageText = ""
                } label: {
                    Image(systemName: "paperplane.fill")
                }.disabled(messageText.isEmpty)
            }.padding()
        }
        .navigationTitle(store.chats[chatId] ?? "Чат")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            client.loadHistory(chatId: chatId)
        }
    }
}

#Preview {
    ContentView()
}
