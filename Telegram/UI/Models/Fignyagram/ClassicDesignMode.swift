import Foundation
import Combine
import UIKit
import SwiftUI

/// App-level recreation of the pre-iOS 26 chrome. iOS does not expose a runtime
/// switch for the system Liquid Glass design, so this flattens UIKit bars and
/// surfaces as far as public APIs allow.
@MainActor
final class ClassicDesignMode: ObservableObject {
    static let shared = ClassicDesignMode()
    private static let key = "classicIOS18Design"

    @Published private(set) var isEnabled: Bool

    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
        applyAppearance()
    }

    func setEnabled(_ enabled: Bool) {
        guard Self.isAvailable || !enabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.key)
        applyAppearance()
    }

    func applyAppearance() {
        let navigation = UINavigationBarAppearance()
        let tab = UITabBarAppearance()

        if isEnabled {
            navigation.configureWithOpaqueBackground()
            navigation.backgroundColor = .systemBackground
            navigation.shadowColor = .separator
            navigation.titleTextAttributes = [.foregroundColor: UIColor.label]

            tab.configureWithOpaqueBackground()
            tab.backgroundEffect = nil
            tab.backgroundColor = .systemBackground
            tab.shadowColor = .separator
        } else {
            navigation.configureWithDefaultBackground()
            tab.configureWithDefaultBackground()
        }

        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = navigation
        navBar.compactAppearance = navigation
        navBar.scrollEdgeAppearance = navigation
        navBar.compactScrollEdgeAppearance = navigation

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tab
        tabBar.scrollEdgeAppearance = tab
    }
}

/// iOS 18-like circular icon button used in bars when classic mode is active.
struct ClassicIconButtonModifier: ViewModifier {
    @ObservedObject private var mode = ClassicDesignMode.shared

    func body(content: Content) -> some View {
        if mode.isEnabled {
            content
                .padding(7)
                .background(Circle().fill(Color(.secondarySystemBackground)))
                .overlay(Circle().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        } else {
            content
        }
    }
}

extension View {
    func classicIconButton() -> some View {
        modifier(ClassicIconButtonModifier())
    }
}
