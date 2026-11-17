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

    /// Sets or clears a zone's shortcut. A combination can only belong to one zone per layout,
    /// so it is removed from the layout's other zones.
    func setShortcut(_ combo: KeyCombo?, for zoneID: UUID, in layoutID: UUID) {
        var shortcuts = config.zoneShortcuts
        if let combo, let layout = layout(id: layoutID) {
            for zone in layout.zones where zone.id != zoneID && shortcuts[zone.id.uuidString] == combo {
                shortcuts[zone.id.uuidString] = nil
            }
        }
        shortcuts[zoneID.uuidString] = combo
        config.zoneShortcuts = shortcuts
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
