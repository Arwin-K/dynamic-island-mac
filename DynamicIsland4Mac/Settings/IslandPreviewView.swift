import SwiftUI

/// A live preview of the island in every state, drawn with the real island views and the
/// theme being edited, on a fake menu bar. Shown in Settings → Appearance.
struct IslandPreviewGallery: View {
    let services: AppServices
    @State private var models: [IslandViewModel] = []

    var body: some View {
        let palette = services.themeStore.palette
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(models, id: \.state) { model in
                    VStack(spacing: 4) {
                        IslandPreviewTile(model: model)
                        Text(model.state.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(palette.isDark ? "Previewing the dark variant. Changes below apply live, here and on your notch." : "Previewing the light variant. Changes below apply live, here and on your notch.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .onAppear(perform: makeModels)
    }

    private func makeModels() {
        guard models.isEmpty else { return }
        let geometry = services.islands.first(where: { $0.geometry.hasNotch })?.geometry ?? Self.sampleGeometry
        let previewModules = ModuleRegistry.makePreviewModules(services: services)
        let modules = ModuleManager(services: services, modules: previewModules, isPreview: true)
        modules.setPreviewAlert(ModuleRegistry.makePreviewAlert(services: services, modules: previewModules))
        models = [IslandState.collapsed, .compact, .alert, .expanded].map {
            IslandViewModel(services: services, geometry: geometry, modules: modules, previewState: $0)
        }
    }

    /// A 14" MacBook Pro notch, used when this Mac has none.
    static let sampleGeometry = NotchGeometry(
        kind: .notch,
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        baseRect: CGRect(x: 662, y: 950, width: 188, height: 32),
        menuBarHeight: 32
    )
}

/// One state, on a strip of fake menu bar, scaled down to fit.
private struct IslandPreviewTile: View {
    let model: IslandViewModel

    var body: some View {
        let widest = model.islandSize(for: .expanded).width
        let island = model.islandSize(for: model.state)
        let canvas = CGSize(width: widest + 40, height: island.height + 26)
        let scale: CGFloat = 0.55
        ZStack(alignment: .top) {
            // Fake desktop + menu bar so the notch-black blends the way it does on screen.
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)
            Rectangle()
                .fill(Color(white: 0.12))
                .frame(height: model.geometry.baseRect.height)
            // The hardware notch, drawn under the island like the real thing.
            NotchShape(topCurve: 0, bottomRadius: 9)
                .fill(.black)
                .frame(width: model.geometry.baseRect.width, height: model.geometry.baseRect.height)
            IslandRootView(model: model)
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                .allowsHitTesting(false)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipShape(RoundedRectangle(cornerRadius: 10 / scale))
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel("Preview of the \(model.state.rawValue) state")
    }
}
