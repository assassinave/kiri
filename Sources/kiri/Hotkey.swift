import AppKit
import Carbon.HIToolbox

struct HotkeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask (cmdKey, shiftKey, optionKey, controlKey)

    static let `default` = HotkeyCombo(keyCode: UInt32(kVK_ANSI_4),
                                       modifiers: UInt32(controlKey | shiftKey))
    /// ⌃⇧5 pairs with capture's ⌃⇧4, the way macOS pairs ⌘⇧4 / ⌘⇧5.
    static let defaultShowAll = HotkeyCombo(keyCode: UInt32(kVK_ANSI_5),
                                            modifiers: UInt32(controlKey | shiftKey))

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

private let hotkeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, let action = HotkeyManager.Action(rawValue: hotKeyID.id) else { return noErr }
    let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { mgr.onTrigger?(action) }
    return noErr
}

/// Global shortcuts via Carbon RegisterEventHotKey (needs no Accessibility permission).
final class HotkeyManager {
    enum Action: UInt32 {
        case capture = 1
        case showAll = 2
    }

    var onTrigger: ((Action) -> Void)?
    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    /// Returns nil on success, or a human-readable error.
    func register(_ combo: HotkeyCombo, for action: Action) -> String? {
        unregister(action)
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &spec,
                                             Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            if status != noErr { return "Could not install hotkey handler (OSStatus \(status))." }
        }
        let id = EventHotKeyID(signature: OSType(0x434B4E47), id: action.rawValue) // 'CKNG'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == OSStatus(eventHotKeyExistsErr) {
            return "\(combo.displayString) is already used by another app."
        }
        guard status == noErr, let ref else { return "Could not register \(combo.displayString) (OSStatus \(status))." }
        hotKeyRefs[action] = ref
        return nil
    }

    func unregister(_ action: Action) {
        if let ref = hotKeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }
}
