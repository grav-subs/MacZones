import AppKit
import Combine

@MainActor
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()

    @Published var config: Config {
        didSet { scheduleSave() }
    }

    /// True while the editor records a shortcut; global hot keys are paused so the keys reach the recorder.
    @Published var isRecordingShortcut = false
    /// Custom shortcuts that could not be registered (taken by macOS or another app).
    @Published var failedShortcuts: Set<KeyCombo> = []

    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacZones", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            config = decoded
        } else {
            config = Config()
        }
    }

    /// Coalesces rapid changes (e.g. dragging a zone in the editor) into one write.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Layouts

    var allLayouts: [Layout] { LayoutTemplates.all + config.customLayouts }

    func layout(id: UUID) -> Layout? {
        allLayouts.first { $0.id == id }
    }

    func layout(for screen: NSScreen) -> Layout {
        config.screenLayouts[screen.stableID].flatMap(layout(id:)) ?? LayoutTemplates.defaultLayout
    }

    func assign(_ layoutID: UUID, to screen: NSScreen) {
        config.screenLayouts[screen.stableID] = layoutID
    }

    @discardableResult
    func addCustomLayout(basedOn source: Layout? = nil) -> Layout {
        let zones = (source?.zones ?? LayoutTemplates.twoColumns.zones).map { zone in
            var copy = zone
            copy.id = UUID()
            return copy
        }
        let name = source.map { "\($0.name) (kopi)" } ?? "Nyt layout"
        let layout = Layout(id: UUID(), name: name, zones: zones)
        config.customLayouts.append(layout)
        // Copies keep the source's shortcuts; the zones are in the same order.
        if let source {
            for (old, new) in zip(source.zones, zones) {
                config.zoneShortcuts[new.id.uuidString] = config.zoneShortcuts[old.id.uuidString]
            }
        }
        return layout
    }

    func update(_ layout: Layout) {
        guard !layout.isTemplate,
              let index = config.customLayouts.firstIndex(where: { $0.id == layout.id }) else { return }
        config.customLayouts[index] = layout
    }

    func deleteLayout(id: UUID) {
        config.screenLayouts = config.screenLayouts.filter { $0.value != id }
        config.layoutSpacing[id.uuidString] = nil
        layout(id: id)?.zones.forEach { config.zoneShortcuts[$0.id.uuidString] = nil }
        config.customLayouts.removeAll { $0.id == id }
    }

    func spacing(for layoutID: UUID) -> Double {
        config.layoutSpacing[layoutID.uuidString] ?? config.spacing
    }

    /// Pass nil to fall back to the default gap.
    func setSpacing(_ spacing: Double?, for layoutID: UUID) {
        config.layoutSpacing[layoutID.uuidString] = spacing
    }

    // MARK: Shortcuts

    func shortcut(for zoneID: UUID) -> KeyCombo? {
        config.zoneShortcuts[zoneID.uuidString]
    }

    /// Sets or clears a zone's shortcut. A combination belongs to one zone per layout and never also to a fixed size,
    /// so it is removed from those. Returns a note naming where it was removed from, if anywhere.
    @discardableResult
    func setShortcut(_ combo: KeyCombo?, for zoneID: UUID, in layoutID: UUID) -> String? {
        var config = config
        var removed: [String] = []
        if let combo {
            if let layout = layout(id: layoutID) {
                for (index, zone) in layout.zones.enumerated()
                where zone.id != zoneID && config.zoneShortcuts[zone.id.uuidString] == combo {
                    config.zoneShortcuts[zone.id.uuidString] = nil
                    removed.append("zone \(index + 1)")
                }
            }
            for index in config.fixedSizes.indices where config.fixedSizes[index].shortcut == combo {
                config.fixedSizes[index].shortcut = nil
                removed.append(config.fixedSizes[index].name)
            }
        }
        config.zoneShortcuts[zoneID.uuidString] = combo
        self.config = config
        return Self.removedNote(removed)
    }

    // MARK: Fixed sizes

    func fixedSize(id: UUID) -> FixedSize? {
        config.fixedSizes.first { $0.id == id }
    }

    @discardableResult
    func addFixedSize() -> FixedSize {
        let size = FixedSize(name: "Ny størrelse", kind: .pixels, width: 1280, height: 720)
        config.fixedSizes.append(size)
        return size
    }

    func update(_ size: FixedSize) {
        guard let index = config.fixedSizes.firstIndex(where: { $0.id == size.id }) else { return }
        config.fixedSizes[index] = size
    }

    func deleteFixedSize(id: UUID) {
        config.fixedSizes.removeAll { $0.id == id }
    }

    /// Sets or clears a fixed size's shortcut, removing the combination from every zone and other fixed size.
    /// Returns a note naming where it was removed from, if anywhere.
    @discardableResult
    func setShortcut(_ combo: KeyCombo?, forFixedSize id: UUID) -> String? {
        var config = config
        var removed: [String] = []
        if let combo {
            for layout in allLayouts {
                for (index, zone) in layout.zones.enumerated() where config.zoneShortcuts[zone.id.uuidString] == combo {
                    config.zoneShortcuts[zone.id.uuidString] = nil
                    removed.append("zone \(index + 1) i \(layout.name)")
                }
            }
            for index in config.fixedSizes.indices where config.fixedSizes[index].id != id && config.fixedSizes[index].shortcut == combo {
                config.fixedSizes[index].shortcut = nil
                removed.append(config.fixedSizes[index].name)
            }
        }
        if let index = config.fixedSizes.firstIndex(where: { $0.id == id }) {
            config.fixedSizes[index].shortcut = combo
        }
        self.config = config
        return Self.removedNote(removed)
    }

    private static func removedNote(_ names: [String]) -> String? {
        names.isEmpty ? nil : "Fjernet fra \(names.joined(separator: ", "))."
    }

    // MARK: Geometry

    /// Zone rectangles for a screen in global Accessibility coordinates (top-left origin).
    func zoneRects(for screen: NSScreen) -> [CGRect] {
        let layout = layout(for: screen)
        let spacing = spacing(for: layout.id)
        return layout.zones.map { Self.zoneRect($0, in: screen.axVisibleFrame, spacing: spacing) }
    }

    /// The frame a window gets when snapped to `zone` on a screen area `frame`.
    /// The area is inset by gap/2 and each zone by gap/2, giving `spacing` between zones and at the edges.
    static func zoneRect(_ zone: Zone, in frame: CGRect, spacing: Double) -> CGRect {
        let inner = frame.insetBy(dx: spacing / 2, dy: spacing / 2)
        let rect = zone.rect(in: inner).insetBy(dx: spacing / 2, dy: spacing / 2)
        // Round each edge (rather than `integral`, which grows the rect) so typed sizes round-trip exactly.
        let minX = rect.minX.rounded(), minY = rect.minY.rounded()
        return CGRect(x: minX, y: minY, width: rect.maxX.rounded() - minX, height: rect.maxY.rounded() - minY)
    }

    /// Inverse of `zoneRect`: the normalized zone that snaps to `rect` (relative to `frame`'s origin).
    static func zone(for rect: CGRect, in frame: CGRect, spacing: Double, id: UUID) -> Zone {
        let innerWidth = max(frame.width - spacing, 1)
        let innerHeight = max(frame.height - spacing, 1)
        return Zone(
            id: id,
            x: (rect.minX - spacing) / innerWidth,
            y: (rect.minY - spacing) / innerHeight,
            width: (rect.width + spacing) / innerWidth,
            height: (rect.height + spacing) / innerHeight
        )
    }
}
