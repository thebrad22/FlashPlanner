import SwiftUI
import Observation

// MARK: - Theme Model

struct AppTheme: Identifiable {
    var id: String { key }
    let key: String
    var name: String
    var accent: Color
    var background: Color
    var gradient: LinearGradient
    var emoji: String

    static let `default` = AppTheme(
        key: "default",
        name: "Default",
        accent: .blue,
        background: Color(uiColor: .systemBackground),
        gradient: LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
        emoji: "✨"
    )
}

typealias Theme = AppTheme

// MARK: - Theme Presets

enum ThemeCatalog {
    static let all: [AppTheme] = [
        AppTheme(key: "ocean", name: "Ocean", accent: .teal, background: Color(.systemBackground), gradient: LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), emoji: "🌊"),
        AppTheme(key: "sunset", name: "Sunset", accent: .orange, background: Color(.systemBackground), gradient: LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing), emoji: "🌅"),
        AppTheme(key: "forest", name: "Forest", accent: .green, background: Color(.systemBackground), gradient: LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing), emoji: "🌲"),
        AppTheme(key: "grape", name: "Grape", accent: .purple, background: Color(.systemBackground), gradient: LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), emoji: "🍇"),
        AppTheme.default
    ]
    static let defaultTheme: AppTheme = .default

    static func byKey(_ key: String) -> AppTheme { all.first(where: { $0.key == key }) ?? .default }
}

// MARK: - Theme Manager

@Observable
final class ThemeManager {
    var globalTheme: AppTheme = .default

    func themeForGroup(key: String?) -> AppTheme {
        guard let key, !key.isEmpty else { return globalTheme }
        return ThemeCatalog.byKey(key)
    }
}

// MARK: - View Helpers

extension View {
    func socialCardStyle(theme: AppTheme) -> some View {
        self
            .padding(14)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: theme.accent.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    func themedToolbarBackground(_ theme: AppTheme) -> some View {
        self.toolbarBackground(theme.accent.opacity(0.12), for: .navigationBar)
            .toolbarColorScheme(nil, for: .navigationBar)
    }
}

