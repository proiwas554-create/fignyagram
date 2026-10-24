import SwiftUI

/// Runtime build information. Values are read from the installed bundle, so a
/// sideload/TestFlight update immediately changes what is shown — nothing is
/// hardcoded. The install date comes from the executable's modification date
/// and therefore changes with every new build.
enum AppBuildInfo {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    static var installDate: Date? {
        guard let url = Bundle.main.executableURL,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    static var installDateText: String? {
        guard let installDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: installDate)
    }

    static var display: String {
        var value = "v\(shortVersion) (\(buildNumber))"
        if let date = installDateText { value += " · \(date)" }
        return value
    }
}

struct AppVersionLabel: View {
    var color: Color = .secondary
    var body: some View {
        Text(verbatim: AppBuildInfo.display)
            .font(.appCaption)
            .foregroundColor(color)
            .monospacedDigit()
    }
}
