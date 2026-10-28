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
                Text(L10n.t("Auto.e83a0c54eb"))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 30)
                Button(L10n.t("Auto.483c36c9a1")) { showScanner = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(L10n.t("Auto.107939c34e"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRCodeScannerSheet { code in
                    scannedCode = code
                    showResult = true
                }
            }
            .alert(L10n.t("Auto.26727ccb54"), isPresented: $showResult) {
                if let scannedCode {
                    Button(L10n.t("Auto.112b141bc7")) {
                        UIPasteboard.general.string = scannedCode
                    }
                    if let url = URL(string: scannedCode),
                       let scheme = url.scheme?.lowercased(),
                       ["http", "https", "tg"].contains(scheme) {
                        Button(L10n.t("Common.Open")) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button(L10n.t("Common.Close"), role: .cancel) {}
            } message: {
                Text(scannedCode ?? "")
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { showScanner = true }
    }
}
