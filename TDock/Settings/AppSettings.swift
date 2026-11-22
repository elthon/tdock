import Combine
import SwiftTerm
import SwiftUI
import TDockCore

/// 应用设置（UserDefaults）。均为非敏感偏好，不含任何凭据。
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let theme = "terminal.theme"
        static let fontSize = "terminal.fontSize"
        static let iCloud = "sync.icloud"
        static let faceID = "security.faceID"
        static let shortcuts = "keyboard.shortcutLayout"
        static let snippets = "keyboard.snippets"
        static let privacyScreen = "security.privacyScreen"
    }

    private let defaults: UserDefaults

    @Published var themeID: String { didSet { defaults.set(themeID, forKey: Key.theme) } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: Key.fontSize) } }
    @Published var iCloudSyncEnabled: Bool { didSet { defaults.set(iCloudSyncEnabled, forKey: Key.iCloud) } }
    @Published var faceIDEnabled: Bool { didSet { defaults.set(faceIDEnabled, forKey: Key.faceID) } }
    @Published var shortcutLayout: ShortcutLayout {
        didSet { defaults.set(try? JSONEncoder().encode(shortcutLayout), forKey: Key.shortcuts) }
    }
    /// 指令片段（Agent 抽屉中一键发送）。
    @Published var snippets: [Snippet] {
        didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: Key.snippets) }
    }
    /// 进入多任务切换器 / 下拉通知中心时用毛玻璃遮住内容（开启 Face ID 锁时总是生效）。
    @Published var privacyScreenEnabled: Bool { didSet { defaults.set(privacyScreenEnabled, forKey: Key.privacyScreen) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        themeID = defaults.string(forKey: Key.theme) ?? TerminalTheme.defaultID
        let size = defaults.double(forKey: Key.fontSize)
        fontSize = size == 0 ? TerminalTheme.defaultFontSize : size
        iCloudSyncEnabled = defaults.object(forKey: Key.iCloud) as? Bool ?? true
        faceIDEnabled = defaults.bool(forKey: Key.faceID)
        shortcutLayout = defaults.data(forKey: Key.shortcuts)
            .flatMap { try? JSONDecoder().decode(ShortcutLayout.self, from: $0) } ?? .default
        snippets = defaults.data(forKey: Key.snippets)
            .flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? Snippet.defaults
        privacyScreenEnabled = defaults.bool(forKey: Key.privacyScreen)
    }

    /// 是否在非活跃状态遮住屏幕内容。
    var shouldObscureWhenInactive: Bool { faceIDEnabled || privacyScreenEnabled }

    var theme: TerminalTheme { TerminalTheme.named(themeID) }

    /// 外观相关设置变化（主题、字号）。
    var appearanceChanges: AnyPublisher<Void, Never> {
        Publishers.Merge($themeID.map { _ in () }, $fontSize.removeDuplicates().map { _ in () })
            .dropFirst(2)
            .eraseToAnyPublisher()
    }

    func adjustFontSize(by delta: Double) {
        fontSize = Self.clampFontSize(fontSize + delta)
    }

    static func clampFontSize(_ size: Double) -> Double {
        min(max(size.rounded(), TerminalTheme.fontSizeRange.lowerBound), TerminalTheme.fontSizeRange.upperBound)
    }

    static func terminalFont(size: Double) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    /// 把主题与字号应用到终端视图。
    func apply(to view: TerminalView) {
        let theme = self.theme
        let font = Self.terminalFont(size: fontSize)
        if view.font != font {
            view.font = font // 字体不变时不重排，避免多余的重绘与窗口尺寸通知
        }
        view.nativeForegroundColor = UIColor(theme.foreground)
        view.nativeBackgroundColor = UIColor(theme.background)
        view.caretColor = UIColor(theme.cursor)
        view.installColors(theme.ansi.map {
            SwiftTerm.Color(red8: UInt16($0.red), green8: UInt16($0.green), blue8: UInt16($0.blue))
        })
        view.keyboardAppearance = theme.isLight ? .light : .dark
    }
}

extension UIColor {
    convenience init(_ rgb: TerminalTheme.RGB) {
        self.init(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}

extension SwiftUI.Color {
    init(_ rgb: TerminalTheme.RGB) {
        self.init(uiColor: UIColor(rgb))
    }
}
