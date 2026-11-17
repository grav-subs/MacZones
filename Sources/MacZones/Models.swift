import Foundation

/// A zone in normalized coordinates (0...1) with origin in the top-left corner.
struct Zone: Codable, Identifiable, Hashable {
    var id = UUID()
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func rect(in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + x * frame.width,
            y: frame.minY + y * frame.height,
            width: width * frame.width,
            height: height * frame.height
        )
    }
}

struct Layout: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var zones: [Zone]
    var isTemplate: Bool = false
}

enum Activation: String, Codable, CaseIterable, Identifiable {
    case shift
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shift: "Hold ⇧ Shift nede mens du trækker"
        case .always: "Altid (hold ⇧ Shift for at slå fra)"
        }
    }
}

struct Config: Codable {
    var customLayouts: [Layout] = []
    /// Display UUID -> layout id.
    var screenLayouts: [String: UUID] = [:]
    /// Default gap in points between zones and around the screen edge.
    var spacing: Double = 8
    /// Per-layout gap overriding `spacing`, keyed by layout id.
    var layoutSpacing: [String: Double] = [:]
    var activation: Activation = .shift
    var hotkeysEnabled = true
    /// Custom shortcut per zone, keyed by zone id. Template zones have fixed ids, so this works for templates too.
    var zoneShortcuts: [String: KeyCombo] = [:]
    /// Window sizes outside any layout, available on every screen via their own shortcut.
    var fixedSizes: [FixedSize] = FixedSize.examples

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        customLayouts = try c.decodeIfPresent([Layout].self, forKey: .customLayouts) ?? defaults.customLayouts
        screenLayouts = try c.decodeIfPresent([String: UUID].self, forKey: .screenLayouts) ?? defaults.screenLayouts
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? defaults.spacing
        layoutSpacing = try c.decodeIfPresent([String: Double].self, forKey: .layoutSpacing) ?? defaults.layoutSpacing
        activation = try c.decodeIfPresent(Activation.self, forKey: .activation) ?? defaults.activation
        hotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeysEnabled) ?? defaults.hotkeysEnabled
        zoneShortcuts = try c.decodeIfPresent([String: KeyCombo].self, forKey: .zoneShortcuts) ?? defaults.zoneShortcuts
        fixedSizes = try c.decodeIfPresent([FixedSize].self, forKey: .fixedSizes) ?? defaults.fixedSizes
    }
}

enum LayoutTemplates {
    static let focus = template("00000000-0000-0000-0000-000000000001", "Fokus", [
        Zone(x: 0.1, y: 0.05, width: 0.8, height: 0.9),
    ])
    static let twoColumns = template("00000000-0000-0000-0000-000000000002", "2 kolonner", columns([0.5, 0.5]))
    static let threeColumns = template("00000000-0000-0000-0000-000000000003", "3 kolonner", columns([1 / 3, 1 / 3, 1 / 3]))
    static let priority = template("00000000-0000-0000-0000-000000000004", "Prioritet", columns([0.25, 0.5, 0.25]))
    static let sixtyForty = template("00000000-0000-0000-0000-000000000005", "60 / 40", columns([0.6, 0.4]))
    static let rows = template("00000000-0000-0000-0000-000000000006", "2 rækker", [
        Zone(x: 0, y: 0, width: 1, height: 0.5),
        Zone(x: 0, y: 0.5, width: 1, height: 0.5),
    ])
    static let grid2x2 = template("00000000-0000-0000-0000-000000000007", "Gitter 2×2", grid(rows: 2, columns: 2))
    static let grid3x2 = template("00000000-0000-0000-0000-000000000008", "Gitter 3×2", grid(rows: 2, columns: 3))

    static let all = [priority, twoColumns, threeColumns, sixtyForty, rows, grid2x2, grid3x2, focus]
    static let defaultLayout = priority

    /// Template zones get fixed ids derived from the layout id and their position, so settings keyed by zone id
    /// (such as shortcuts) survive relaunches.
    private static func template(_ id: String, _ name: String, _ zones: [Zone]) -> Layout {
        let layoutID = UUID(uuidString: id)!
        let fixed = zones.enumerated().map { index, zone in
            var copy = zone
            let prefix = String(format: "00000000-0000-%04X", index + 1)
            copy.id = UUID(uuidString: prefix + id.dropFirst(prefix.count))!
            return copy
        }
        return Layout(id: layoutID, name: name, zones: fixed, isTemplate: true)
    }

    private static func columns(_ widths: [Double]) -> [Zone] {
        var x = 0.0
        return widths.map { w in
            defer { x += w }
            return Zone(x: x, y: 0, width: w, height: 1)
        }
    }

    private static func grid(rows: Int, columns: Int) -> [Zone] {
        (0..<rows).flatMap { r in
            (0..<columns).map { c in
                Zone(
                    x: Double(c) / Double(columns),
                    y: Double(r) / Double(rows),
                    width: 1 / Double(columns),
                    height: 1 / Double(rows)
                )
            }
        }
    }
}

/// A key plus Carbon modifier flags (`cmdKey`, `optionKey`, …), as passed to `RegisterEventHotKey`.
struct KeyCombo: Codable, Hashable {
    var keyCode: Int
    var modifiers: Int
    /// Label for the key itself, e.g. "←" or "K", captured when the shortcut was recorded.
    var key: String

    static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }
}

/// A window size that is not part of a layout. The window is centered on its screen.
struct FixedSize: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Exact size in points, scaled down (keeping the ratio) if it doesn't fit.
        case pixels
        /// The largest window with this aspect ratio that fits.
        case ratio
        /// Percent of the screen's usable area.
        case percent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pixels: "Pixels"
            case .ratio: "Forhold"
            case .percent: "Procent"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var width: Double
    var height: Double
    var shortcut: KeyCombo?

    static let examples = [
        FixedSize(id: UUID(uuidString: "00000000-0000-0000-0001-000000000001")!, name: "Fokus", kind: .percent, width: 80, height: 90),
        FixedSize(id: UUID(uuidString: "00000000-0000-0000-0001-000000000002")!, name: "16:9", kind: .ratio, width: 16, height: 9),
    ]

    /// The window frame on a screen area `frame`, centered and rounded to whole points.
    func rect(in frame: CGRect) -> CGRect {
        let w = max(width, 1), h = max(height, 1)
        var size: CGSize
        switch kind {
        case .pixels:
            let scale = min(frame.width / w, frame.height / h, 1)
            size = CGSize(width: w * scale, height: h * scale)
        case .ratio:
            let scale = min(frame.width / w, frame.height / h)
            size = CGSize(width: w * scale, height: h * scale)
        case .percent:
            size = CGSize(width: frame.width * min(w, 100) / 100, height: frame.height * min(h, 100) / 100)
        }
        size = CGSize(width: size.width.rounded(.down), height: size.height.rounded(.down))
        let origin = CGPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded())
        return CGRect(origin: origin, size: size)
    }
}
