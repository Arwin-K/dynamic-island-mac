import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// File shelf: drop files on the island to hold them, drag them out again later, or AirDrop
/// them. Holds references (the files stay where they are), and lives only until you quit.
@MainActor
@Observable
final class ShelfModule: IslandModule {
    let id = "shelf"
    let displayName = "File Shelf"
    let symbolName = "tray.full"
    let priority = 70
    let showsInExpandedWhenIdle = true

    @ObservationIgnored let context: ModuleContext
    private(set) var items: [URL] = []

    init(context: ModuleContext) {
        self.context = context
    }

    var showInCompact: Bool { context.bool("showInCompact", default: true) }
    var isActive: Bool { showInCompact && !items.isEmpty }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
    }

    func remove(_ url: URL) { items.removeAll { $0 == url } }
    func clear() { items.removeAll() }

    func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    func share(_ urls: [URL], from view: NSView?) {
        let picker = NSSharingServicePicker(items: urls)
        if let view { picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY) }
    }

    // MARK: Views

    func compactLeading() -> some View {
        Image(systemName: "tray.full.fill")
            .font(.system(size: 12, weight: .semibold))
            .islandMatched("tray", module: id)
            .accessibilityHidden(true)
    }

    func compactTrailing() -> some View {
        ShelfCountText(count: items.count)
    }

    func expanded() -> some View {
        ShelfExpandedView(module: self)
    }

    func settingsView() -> AnyView {
        AnyView(Toggle("Show the shelf in the compact island while it holds files", isOn: context.boolBinding("showInCompact", default: true)))
    }

    static func preview(context: ModuleContext) -> ShelfModule {
        let module = ShelfModule(context: context)
        module.items = [URL(fileURLWithPath: "/System/Applications/Notes.app"), URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")]
        return module
    }
}

private struct ShelfCountText: View {
    let count: Int
    @Environment(\.islandTheme) private var theme

    var body: some View {
        Text("\(count)")
            .font(theme.font(size: theme.typography.bodySize, weight: .semibold, monospacedDigits: true))
            .accessibilityLabel("\(count) files on the shelf")
    }
}

struct ShelfExpandedView: View {
    let module: ShelfModule
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        if module.items.isEmpty {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(palette.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 20, weight: theme.icons.weight.weight))
                        Text("Drop files here to hold them").font(theme.bodyFont)
                        Text("Drag them out later, or AirDrop them").font(theme.captionFont).foregroundStyle(palette.secondary)
                    }
                    .foregroundStyle(palette.secondary)
                }
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
        } else {
            VStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(module.items, id: \.self) { url in
                            ShelfTile(url: url) { module.remove(url) }
                        }
                    }
                    .padding(.top, 2)
                }
                HStack {
                    Button {
                        module.airDrop(module.items)
                    } label: {
                        Label("AirDrop", systemImage: "airplayaudio")
                    }
                    .accessibilityLabel("AirDrop all files")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(module.items)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Spacer()
                    Button {
                        module.clear()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                }
                .buttonStyle(.plain)
                .labelStyle(.titleAndIcon)
                .font(theme.captionFont)
                .foregroundStyle(palette.secondary)
            }
        }
    }
}

private struct ShelfTile: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandPalette) private var palette

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(theme.captionFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 70)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.foreground.opacity(hovering ? 0.12 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(url.lastPathComponent) from the shelf")
            }
        }
        .onHover { hovering = $0 }
        // Dragging out hands the real file to the drop target (Finder copies/moves as usual).
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint("Drag to move or copy it somewhere")
    }
}
