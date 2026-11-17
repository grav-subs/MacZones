import AppKit
import Carbon

/// Global keyboard shortcuts via the Carbon hot key API (no extra permission required).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    /// Returns false if the combination could not be registered, e.g. because it is already taken.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4D5A_4E53), id: nextID) // "MZNS"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[nextID] = handler
        nextID += 1
        return true
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum Shortcuts {
    static let modifiers = controlKey | optionKey
    static let numberKeys = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    /// Registers the built-in shortcuts plus every custom zone and fixed size shortcut.
    /// Returns the custom combinations that could not be registered.
    @MainActor
    static func register(engine: ZoneEngine, zoneShortcuts: Set<KeyCombo>, fixedSizes: [UUID: KeyCombo]) -> Set<KeyCombo> {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        center.register(keyCode: kVK_LeftArrow, modifiers: modifiers) { engine.moveFocusedWindow(by: -1) }
        center.register(keyCode: kVK_RightArrow, modifiers: modifiers) { engine.moveFocusedWindow(by: 1) }
        for (index, key) in numberKeys.enumerated() {
            center.register(keyCode: key, modifiers: modifiers) { engine.moveFocusedWindow(toZone: index + 1) }
        }
        // The same combination may be used in several layouts; it is registered once and resolved when pressed.
        var failed = Set<KeyCombo>()
        for (id, combo) in fixedSizes {
            let ok = center.register(keyCode: combo.keyCode, modifiers: combo.modifiers) {
                engine.applyFixedSize(id: id)
            }
            if !ok { failed.insert(combo) }
        }
        // The store keeps a combination off zones once a fixed size has it; skip it here too, just in case.
        let fixedCombos = Set(fixedSizes.values)
        for combo in zoneShortcuts where !fixedCombos.contains(combo) {
            let ok = center.register(keyCode: combo.keyCode, modifiers: combo.modifiers) {
                engine.moveFocusedWindow(toZoneWith: combo)
            }
            if !ok { failed.insert(combo) }
        }
        return failed
    }
}

extension KeyCombo {
    /// Builds a combination from a key press, or nil if it has no ⌘, ⌃ or ⌥ (plain keys must keep typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        let keyCode = Int(event.keyCode)
        let label = Self.specialKeys[keyCode]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty else { return nil }
        self.init(keyCode: keyCode, modifiers: carbon, key: label)
    }

    /// E.g. "⌃⌥⌘←", in the standard macOS modifier order.
    var displayString: String {
        var result = ""
        if modifiers & controlKey != 0 { result += "⌃" }
        if modifiers & optionKey != 0 { result += "⌥" }
        if modifiers & shiftKey != 0 { result += "⇧" }
        if modifiers & cmdKey != 0 { result += "⌘" }
        return result + key
    }

    private static let specialKeys: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Mellemrum",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
