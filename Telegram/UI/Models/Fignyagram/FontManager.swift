import Foundation
import SwiftUI
import UIKit
import CoreText
import Combine

@MainActor
final class FontManager: ObservableObject {
    static let shared = FontManager()
    private static let selectionKey = "selectedAppFont"
    private static let customNamesKey = "customAppFontNames"

    enum Builtin: String, CaseIterable, Identifiable {
        case system, rounded, serif, monospaced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Системный"
            case .rounded: return "Округлый"
            case .serif: return "Serif"
            case .monospaced: return "Моноширинный"
            }
        }
    }

    @Published private(set) var selection: String
    @Published private(set) var customNames: [String] = []
    @Published private(set) var revision = 0

    private let directory: URL
    private let fileManager = FileManager.default

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Fonts", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        selection = UserDefaults.standard.string(forKey: Self.selectionKey) ?? Builtin.system.rawValue
        customNames = UserDefaults.standard.stringArray(forKey: Self.customNamesKey) ?? []
        registerAll()
        applyGlobalAppearance()
    }

    var builtinSelection: Builtin? { Builtin(rawValue: selection) }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let builtin = builtinSelection {
            switch builtin {
            case .system: return .system(size: size, weight: weight)
            case .rounded: return .system(size: size, weight: weight, design: .rounded)
            case .serif: return .system(size: size, weight: weight, design: .serif)
            case .monospaced: return .system(size: size, weight: weight, design: .monospaced)
            }
        }
        return .custom(selection, size: size)
    }

    var bodyFont: Font { font(size: 17) }

    func select(_ value: String) {
        selection = value
        UserDefaults.standard.set(value, forKey: Self.selectionKey)
        revision += 1
        if value == Builtin.system.rawValue {
            // Back to factory typography: drop every UIKit override so no stale
            // custom font survives in bars, menus or segmented controls.
            applySystemTypography()
        } else {
            applyGlobalAppearance()
        }
        GlobalUI.bump()
    }

    /// Restores Apple's default typography for UIKit-backed chrome.
    private func applySystemTypography() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactScrollEdgeAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        for item in [tab.stackedLayoutAppearance,
                     tab.inlineLayoutAppearance,
                     tab.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [:]
            item.selected.titleTextAttributes = [:]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UIBarButtonItem.appearance().setTitleTextAttributes([:], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([:], for: .normal)
    }

    /// Applies the chosen typeface to UIKit-backed bars, menus and alerts.
    /// SwiftUI views receive the same font through the root environment.
    func applyGlobalAppearance() {
        let titleFont = uiFont(size: 17, weight: .semibold)
        let bodyFont = uiFont(size: 17, weight: .regular)

        if let existing = UINavigationBar.appearance().standardAppearance.copy() as? UINavigationBarAppearance {
            existing.titleTextAttributes = [.font: titleFont]
            existing.largeTitleTextAttributes = [.font: uiFont(size: 34, weight: .bold)]
            UINavigationBar.appearance().standardAppearance = existing
            UINavigationBar.appearance().compactAppearance = existing
            UINavigationBar.appearance().scrollEdgeAppearance = existing
            UINavigationBar.appearance().compactScrollEdgeAppearance = existing
        }

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        for item in [tabAppearance.stackedLayoutAppearance,
                     tabAppearance.inlineLayoutAppearance,
                     tabAppearance.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: uiFont(size: 10, weight: .medium)]
            item.selected.titleTextAttributes = [.font: uiFont(size: 10, weight: .semibold)]
        }
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        UIBarButtonItem.appearance().setTitleTextAttributes([.font: bodyFont], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.font: uiFont(size: 13)], for: .normal)
    }

    private func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        if let builtin = builtinSelection {
            let descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            let design: UIFontDescriptor.SystemDesign
            switch builtin {
            case .rounded: design = .rounded
            case .serif: design = .serif
            case .monospaced: design = .monospaced
            case .system: return UIFont.systemFont(ofSize: size, weight: weight)
            }
            return UIFont(descriptor: descriptor.withDesign(design) ?? descriptor, size: size)
        }
        return UIFont(name: selection, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight)
    }

    func importFont(from url: URL) throws {
        let ext = url.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc"].contains(ext) else {
            throw NSError(domain: "FontManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Нужен файл TTF, OTF или TTC"])
        }
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try fileManager.copyItem(at: url, to: destination)
        guard let postScriptName = register(url: destination) else {
            try? fileManager.removeItem(at: destination)
            throw NSError(domain: "FontManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось зарегистрировать шрифт"])
        }
        if !customNames.contains(postScriptName) {
            customNames.append(postScriptName)
            UserDefaults.standard.set(customNames, forKey: Self.customNamesKey)
        }
        select(postScriptName)
    }

    func removeCustomFont(_ name: String) {
        customNames.removeAll { $0 == name }
        UserDefaults.standard.set(customNames, forKey: Self.customNamesKey)
        if selection == name { select(Builtin.system.rawValue) }
    }

    private func registerAll() {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { _ = register(url: file) }
    }

    @discardableResult
    private func register(url: URL) -> String? {
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            return nil
        }
        return name
    }
}

@MainActor
extension Font {
    static var appLargeTitle: Font { FontManager.shared.font(size: 34, weight: .bold) }
    static var appTitle: Font { FontManager.shared.font(size: 28) }
    static var appTitle2: Font { FontManager.shared.font(size: 22) }
    static var appTitle3: Font { FontManager.shared.font(size: 20) }
    static var appHeadline: Font { FontManager.shared.font(size: 17, weight: .semibold) }
    static var appBody: Font { FontManager.shared.font(size: 17) }
    static var appCallout: Font { FontManager.shared.font(size: 16) }
    static var appSubheadline: Font { FontManager.shared.font(size: 15) }
    static var appFootnote: Font { FontManager.shared.font(size: 13) }
    static var appCaption: Font { FontManager.shared.font(size: 12) }
    static var appCaption2: Font { FontManager.shared.font(size: 11) }
}


/// Applies the selected font to every screen and rebuilds the tree when the
/// selection changes, so lists, terminal, player and call menus update at once.
struct FignyagramFontModifier: ViewModifier {
    @ObservedObject private var fonts = FontManager.shared

    func body(content: Content) -> some View {
        content
            .font(.appBody)
            .id(fonts.revision)
    }
}

extension View {
    func fignyagramFont() -> some View { modifier(FignyagramFontModifier()) }
}
