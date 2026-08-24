import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey registered through Carbon's `RegisterEventHotKey`.
///
/// Deliberately not `NSEvent.addGlobalMonitorForEvents`, which would require
/// the user to grant Accessibility access in System Settings. Carbon hotkeys
/// need no permission and are still fully supported on macOS 26.
final class HotKey {
    static let defaultKeyCode = UInt32(kVK_ANSI_O)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    private static let keyCodeDefault = "hotKeyCode"
    private static let modifiersDefault = "hotKeyModifiers"

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    /// Carbon calls back into C, so the trampoline needs a stable pointer to
    /// the live instance.
    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    init(handler: @escaping () -> Void) {
        self.handler = handler
        self.id = Self.nextID
        Self.nextID += 1
        Self.instances[id] = self
    }

    deinit {
        unregister()
        Self.instances[id] = nil
    }

    // MARK: Stored binding

    static func currentBinding() -> (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeDefault) != nil else {
            return (defaultKeyCode, defaultModifiers)
        }
        return (
            UInt32(defaults.integer(forKey: keyCodeDefault)),
            UInt32(defaults.integer(forKey: modifiersDefault))
        )
    }

    /// "⌥⌘O" — shown in the overlay footer so the shortcut is discoverable.
    static func currentDescription() -> String {
        let (keyCode, modifiers) = currentBinding()
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        out += Self.keyName(keyCode)
        return out
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        // Only the letters and digits a user is likely to bind; anything else
        // falls back to the raw code rather than guessing.
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_Space): "Space",
        ]
        return names[keyCode] ?? "#\(keyCode)"
    }

    // MARK: Registration

    @discardableResult
    func register() -> Bool {
        unregister()

        let (keyCode, modifiers) = Self.currentBinding()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    HotKey.instances[hotKeyID.id]?.handler()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x6F6D_6C78), id: id)  // 'omlx'
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if registerStatus != noErr {
            NSLog("omlxbar: could not register \(Self.currentDescription()) (OSStatus \(registerStatus)) — it is probably taken by another app")
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
