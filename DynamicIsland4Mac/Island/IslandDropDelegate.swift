import SwiftUI
import UniformTypeIdentifiers

/// Dropping files anywhere on the island puts them on the File Shelf. Dragging over the
/// collapsed island opens it on the shelf so there's a big target to drop onto.
struct IslandDropDelegate: DropDelegate {
    let model: IslandViewModel

    private var shelf: ShelfModule? {
        guard let module = model.modules.module(id: "shelf"), model.modules.isEnabled(module) else { return nil }
        return module.base as? ShelfModule
    }

    func validateDrop(info: DropInfo) -> Bool {
        shelf != nil && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info), !model.isPreview else { return }
        model.modules.select("shelf")
        if model.state != .expanded { model.open(pinned: true) }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let shelf else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { shelf.add([url]) }
            }
        }
        return !providers.isEmpty
    }
}
