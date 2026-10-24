import SwiftUI
import UIKit

struct UniversalScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = true
    @State private var scannedCode: String?
    @State private var showResult = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
                Text("Сканируйте любой QR-код: ссылку, текст, username или данные.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 30)
                Button("Открыть сканер") { showScanner = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("QR-сканер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRCodeScannerSheet { code in
                    scannedCode = code
                    showResult = true
                }
            }
            .alert("QR-код", isPresented: $showResult) {
                if let scannedCode {
                    Button("Копировать") {
                        UIPasteboard.general.string = scannedCode
                    }
                    if let url = URL(string: scannedCode),
                       let scheme = url.scheme?.lowercased(),
                       ["http", "https", "tg"].contains(scheme) {
                        Button("Открыть") {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("Закрыть", role: .cancel) {}
            } message: {
                Text(scannedCode ?? "")
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { showScanner = true }
    }
}
