import SwiftUI

/// What's drawn inside the island in each state. Content comes from modules; this view only
/// lays it out around the notch.
struct IslandContentView: View {
    let model: IslandViewModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let modules = model.modules
        let reduceMotion = model.services.themeStore.reduceMotion
        let transition: AnyTransition = reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
        let notchHeight = model.geometry.baseRect.height
        let sidePadding = CGFloat(theme.geometry.padding) + model.topCurve

        ZStack(alignment: .top) {
            switch model.state {
            case .collapsed:
                Color.clear
            case .compact:
                if let module = modules.compactModule {
                    CompactRow(module: module, centerGap: model.centerGap, activeCount: modules.active.count)
                        .padding(.horizontal, model.topCurve + 10)
                        .frame(height: notchHeight)
                        .transition(transition)
                        .id(module.id)
                }
            case .alert:
                if let alert = modules.currentAlert {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: notchHeight)
                        alert.content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.horizontal, sidePadding)
                    .padding(.bottom, 6)
                    .transition(transition)
                    .id(alert.id)
                }
            case .expanded:
                ExpandedContainer(model: model, notchHeight: notchHeight)
                    .padding(.horizontal, sidePadding)
                    .padding(.bottom, CGFloat(theme.geometry.padding))
                    .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Leading content | the notch | trailing content.
private struct CompactRow: View {
    let module: AnyIslandModule
    let centerGap: CGFloat
    let activeCount: Int
    @Environment(\.islandPalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if activeCount > 1 {
                    // More activities are waiting: swipe sideways to cycle.
                    Circle()
                        .fill(palette.secondary)
                        .frame(width: 4, height: 4)
                        .accessibilityLabel("\(activeCount - 1) more activities. Swipe sideways to switch.")
                }
                module.compactLeading()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: centerGap)
            module.compactTrailing()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(module.displayName)
    }
}

/// The open island: a tab strip beside the notch, then the selected module's view.
private struct ExpandedContainer: View {
    let model: IslandViewModel
    let notchHeight: CGFloat
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        let modules = model.modules
        let tabs = modules.expandedTabs
        let current = modules.expandedModule
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(tabs.prefix(5)) { tab in
                        Button {
                            modules.select(tab.id)
                        } label: {
                            Image(systemName: tab.symbolName)
                                .font(.system(size: 11, weight: theme.icons.weight.weight))
                                .symbolRenderingMode(theme.icons.rendering.mode)
                                .frame(width: 22, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(palette.foreground.opacity(tab.id == current?.id ? 0.16 : 0))
                                )
                                .foregroundStyle(tab.id == current?.id ? palette.foreground : palette.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.displayName)
                        .accessibilityAddTraits(tab.id == current?.id ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: model.centerGap)
                HStack {
                    Spacer()
                    Button {
                        SettingsOpener.open(.modules)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: theme.icons.weight.weight))
                            .foregroundStyle(palette.secondary)
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: notchHeight)

            if let current {
                current.expanded()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(current.id)
                    .transition(.opacity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "capsule.portrait")
                        .font(.system(size: 20, weight: theme.icons.weight.weight))
                        .foregroundStyle(palette.accent)
                    Text("Nothing to show yet")
                        .font(theme.titleFont)
                    Text("Turn on modules in Settings → Modules.")
                        .font(theme.captionFont)
                        .foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
