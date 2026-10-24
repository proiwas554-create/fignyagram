import SwiftUI

struct HardwareSettingsView: View {
    @ObservedObject private var tuning = HardwareTuning.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmMax = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Профиль", selection: Binding(
                        get: { tuning.profile },
                        set: { tuning.setProfile($0) }
                    )) {
                        ForEach(HardwareProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Профиль нагрузки")
                } footer: {
                    Text("Экономия снижает декодирование и кэш. Производительность даёт больше параллельных декодирований и высокое качество. Баланс — компромисс.")
                        .font(.appFootnote)
                }

                Section("Устройство") {
                    row("Модель", tuning.device.marketingName)
                    row("Идентификатор", tuning.device.identifier)
                    row("Класс", tuning.device.tier.title)
                    row("Рекомендуемый профиль", tuning.device.recommendedProfile.title)
                    row("Максимальная частота", "\(tuning.device.recommendedRefreshRate) Гц")
                }

                Section("Состояние устройства") {
                    row("Термическое состояние", thermalTitle)
                    row("Режим энергосбережения", tuning.isLowPower ? "включён" : "выключен")
                    row("Память устройства", String(format: "%.0f ГБ", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824))
                }

                Section {
                    Toggle("Максимальная производительность", isOn: Binding(
                        get: { tuning.maxPerformance },
                        set: { enabled in
                            if enabled { confirmMax = true } else { tuning.maxPerformance = false }
                        }
                    ))
                    .tint(.red)
                } header: {
                    Text("На свой страх и риск")
                } footer: {
                    Text("Отключает защитный троттлинг, поднимает декодирование до 4 потоков, кэш до 128 МБ и качество до 2048 px. Устройство может сильнее нагреваться и быстрее разряжаться.")
                        .font(.appFootnote)
                }

                Section {
                    Toggle("Авто-троттлинг при нагреве", isOn: $tuning.autoThrottle)
                } footer: {
                    Text("При сильном нагреве или включённом энергосбережении приложение автоматически перейдёт в экономичный профиль. Это не меняет функции, только качество декодирования и кэш.")
                        .font(.appFootnote)
                }
            }
            .navigationTitle("Производительность")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .confirmationDialog("Включить максимальную производительность?", isPresented: $confirmMax, titleVisibility: .visible) {
                Button("Включить на свой страх и риск", role: .destructive) {
                    tuning.maxPerformance = true
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Нагрузка на процессор и нагрев возрастут. Стабильность не гарантируется.")
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
        @unknown default: return "неизвестно"
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
