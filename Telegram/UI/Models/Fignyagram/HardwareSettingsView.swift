import SwiftUI

struct HardwareSettingsView: View {
    @ObservedObject private var tuning = HardwareTuning.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmMax = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker(L10n.t("Common.Profile"), selection: Binding(
                        get: { tuning.profile },
                        set: { tuning.setProfile($0) }
                    )) {
                        ForEach(HardwareProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(L10n.t("Auto.350332afc7"))
                } footer: {
                    Text(L10n.t("Auto.a5c2d2baf8"))
                        .font(.appFootnote)
                }

                Section(L10n.t("Auto.72275dacae")) {
                    row(NSLocalizedString("Generated.ee4b7b031c58", comment: ""), tuning.device.marketingName)
                    row(L10n.t("Hw.Identifier"), tuning.device.identifier)
                    row(L10n.t("Hw.Class"), tuning.device.tier.title)
                    row(NSLocalizedString("Generated.d736188bbd15", comment: ""), tuning.device.recommendedProfile.title)
                    row(L10n.t("Hw.MaxFreq"), "\(tuning.device.recommendedRefreshRate) Гц")
                }

                Section(L10n.t("Auto.8f8c377196")) {
                    row(NSLocalizedString("Generated.5d5ebcceba4d", comment: ""), thermalTitle)
                    row(NSLocalizedString("Generated.fb74c99c2019", comment: ""), tuning.isLowPower ? NSLocalizedString("Generated.e59094ed9041", comment: "") : NSLocalizedString("Generated.5943ad965d17", comment: ""))
                    row(NSLocalizedString("Generated.729b9f5426ee", comment: ""), String(format: NSLocalizedString("Generated.eb3153f1094e", comment: ""), Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824))
                }

                Section {
                    Toggle(L10n.t("Hw.MaxPerf"), isOn: Binding(
                        get: { tuning.maxPerformance },
                        set: { enabled in
                            if enabled { confirmMax = true } else { tuning.maxPerformance = false }
                        }
                    ))
                    .tint(.red)
                } header: {
                    Text(L10n.t("Auto.6dcb746d2e"))
                } footer: {
                    Text(L10n.t("Auto.06cdf21c6c"))
                        .font(.appFootnote)
                }

                Section {
                    Toggle(L10n.t("Hw.Throttle"), isOn: $tuning.autoThrottle)
                } footer: {
                    Text(L10n.t("Auto.54a9b2e388"))
                        .font(.appFootnote)
                }
            }
            .navigationTitle(L10n.t("Auto.a12969d4c3"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Common.Close")) { dismiss() }
                }
            }
            .confirmationDialog(L10n.t("Hw.MaxPerfConfirm"), isPresented: $confirmMax, titleVisibility: .visible) {
                Button(L10n.t("Hw.Risk"), role: .destructive) {
                    tuning.maxPerformance = true
                }
                Button(L10n.t("Common.Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t("Auto.e6e2ce4436"))
            }
        }
        .navigationViewStyle(.stack)
    }

    private var thermalTitle: String {
        switch tuning.thermalState {
        case .nominal: return "нормальное"
        case .fair: return "умеренное"
        case .serious: return "сильный нагрев"
        case .critical: return "критическое"
        @unknown default: return NSLocalizedString("Generated.d755e9e7b1f3", comment: "")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}
