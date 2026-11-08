import Observation
import SwiftUI

/// A presentation-only theme stack. It never writes the viewer's saved theme.
/// Tabs retain their own profile context, and the most recently opened profile
/// wins when a second profile is presented above the first.
@MainActor
@Observable
final class ProfileSceneThemes {
    private struct Presentation {
        let id: UUID
        let tab: AppTab
        var theme: BackgroundTheme
    }

    private var presentations: [Presentation] = []

    func theme(for tab: AppTab) -> BackgroundTheme? {
        presentations.last(where: { $0.tab == tab })?.theme
    }

    func show(_ id: UUID, theme: BackgroundTheme, tab: AppTab) {
        if let index = presentations.firstIndex(where: { $0.id == id }) {
            // A late profile refresh must not take priority over a newer profile.
            presentations[index].theme = theme
        } else {
            presentations.append(Presentation(id: id, tab: tab, theme: theme))
        }
    }

    func remove(_ id: UUID) {
        presentations.removeAll { $0.id == id }
    }
}

private struct ProfileSceneThemesKey: EnvironmentKey {
    static let defaultValue: ProfileSceneThemes? = nil
}

private struct ProfileSceneTabKey: EnvironmentKey {
    static let defaultValue: AppTab? = nil
}

private struct IsProfileSceneThemeActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var profileSceneThemes: ProfileSceneThemes? {
        get { self[ProfileSceneThemesKey.self] }
        set { self[ProfileSceneThemesKey.self] = newValue }
    }

    var profileSceneTab: AppTab? {
        get { self[ProfileSceneTabKey.self] }
        set { self[ProfileSceneTabKey.self] = newValue }
    }

    var isProfileSceneThemeActive: Bool {
        get { self[IsProfileSceneThemeActiveKey.self] }
        set { self[IsProfileSceneThemeActiveKey.self] = newValue }
    }
}

struct ProfileSceneThemeScope: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var themes = ProfileSceneThemes()

    func body(content: Content) -> some View {
        content
            .environment(\.profileSceneThemes, themes)
            .environment(\.appBackgroundTheme, themes.theme(for: store.selectedTab) ?? store.backgroundTheme)
            #if DEBUG
            .task {
                if store.isLayoutPreview {
                    await DuoLayoutFixtures.configureThemePreviewScene(store: store)
                }
                if store.isLayoutPreview,
                   ProcessInfo.processInfo.arguments.contains("--duo-theme-cycle") {
                    await DuoLayoutFixtures.checkProfileThemeFlow(store: store, themes: themes)
                }
            }
            #endif
    }
}

struct ProfileSceneThemeSource: ViewModifier {
    let theme: BackgroundTheme
    @Environment(AppStore.self) private var store
    @Environment(\.profileSceneThemes) private var themes
    @Environment(\.profileSceneTab) private var tab
    @Environment(\.isProfileSceneThemeActive) private var isActive
    @State private var id = UUID()
    @State private var presentedTab: AppTab?

    func body(content: Content) -> some View {
        content
            .onAppear {
                presentedTab = tab ?? store.selectedTab
                synchronize()
            }
            .onChange(of: theme) { _, _ in synchronize() }
            .onChange(of: isActive) { _, _ in synchronize() }
            .onDisappear {
                themes?.remove(id)
                presentedTab = nil
            }
    }

    private func synchronize() {
        if isActive, let presentedTab {
            themes?.show(id, theme: theme, tab: presentedTab)
        } else {
            themes?.remove(id)
        }
    }
}

/// Animate only the backdrop; navigation, text, and scrolling keep their own
/// timing. A real opacity transition preserves both palettes during the fade.
struct BackgroundThemeCrossfade: ViewModifier {
    let theme: BackgroundTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
                .id(theme)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: theme)
    }
}
