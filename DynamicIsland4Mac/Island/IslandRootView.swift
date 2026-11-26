import SwiftUI

/// The SwiftUI root inside each island panel. The island is pinned to the top center of the
/// panel; the panel itself is resized around it (see `IslandWindowController`).
struct IslandRootView: View {
    @Bindable var model: IslandViewModel
    @Namespace private var namespace

    var body: some View {
        let themeStore = model.services.themeStore
        let theme = themeStore.theme
        let palette = themeStore.palette
        let size = model.islandSize
        let shape = model.shape

        ZStack(alignment: .top) {
            IslandSurface(
                theme: theme,
                palette: palette,
                shape: shape,
                blendsIntoNotch: model.state == .collapsed && !model.isFloating,
                increaseContrast: themeStore.increaseContrast
            )

            IslandContentView(model: model)
                .environment(\.islandNamespace, namespace)
                .environment(\.islandPalette, palette)
                .environment(\.islandTheme, theme)
                .foregroundStyle(palette.foreground)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .onHover { model.hoverChanged($0) }
        .onTapGesture { model.tapped() }
        .onDrop(of: [.fileURL], delegate: IslandDropDelegate(model: model))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dynamic Island")
        .accessibilityAddTraits(model.state == .expanded ? [] : .isButton)
        .accessibilityAction(named: model.state == .expanded ? "Close" : "Open") { model.toggle() }
        .opacity(model.isSuppressed ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
    }
}

// MARK: - Environment

private struct IslandNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct IslandPaletteKey: EnvironmentKey {
    static let defaultValue = ResolvedPalette(theme: .default, isDark: true)
}

private struct IslandThemeKey: EnvironmentKey {
    static let defaultValue = Theme.default
}

extension EnvironmentValues {
    /// Namespace for matched-geometry transitions between compact and expanded content.
    var islandNamespace: Namespace.ID? {
        get { self[IslandNamespaceKey.self] }
        set { self[IslandNamespaceKey.self] = newValue }
    }

    var islandPalette: ResolvedPalette {
        get { self[IslandPaletteKey.self] }
        set { self[IslandPaletteKey.self] = newValue }
    }

    var islandTheme: Theme {
        get { self[IslandThemeKey.self] }
        set { self[IslandThemeKey.self] = newValue }
    }
}

extension View {
    /// Fly this view between the compact and expanded layouts instead of popping it in.
    /// Use the same `id` in both places (for example `"artwork"`); ids are scoped per module.
    func islandMatched(_ id: String, module: String) -> some View {
        modifier(IslandMatchedModifier(id: "\(module).\(id)"))
    }
}

private struct IslandMatchedModifier: ViewModifier {
    let id: String
    @Environment(\.islandNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}
