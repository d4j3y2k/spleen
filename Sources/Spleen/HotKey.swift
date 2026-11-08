import AppKit
import Carbon
import SpleenCore

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private var nextID: UInt32 = 0
    private var activeID: UInt32 = 0
    private var registeredShortcut: Shortcut?

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKey>.fromOpaque(pointer).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x53504C4E, id.id == owner.activeID else { return OSStatus(eventNotHandledErr) }
            owner.onPress?()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ shortcut: Shortcut) throws {
        guard shortcut.isValid else { throw SpleenError.invalidSettings }
        if registeredShortcut == shortcut { return }
        guard handler != nil else { throw NSError(domain: "Spleen.HotKey", code: -1, userInfo: [NSLocalizedDescriptionKey: "The hotkey handler could not be installed. Use the menu bar to open Spleen."]) }
        let codes: [String: UInt32] = ["Space": UInt32(kVK_Space), "S": UInt32(kVK_ANSI_S), "K": UInt32(kVK_ANSI_K), "P": UInt32(kVK_ANSI_P)]
        var modifiers: UInt32 = 0
        if shortcut.control { modifiers |= UInt32(controlKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        nextID += 1
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(codes[shortcut.key]!, modifiers,
            EventHotKeyID(signature: 0x53504C4E, id: nextID), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &replacement)
        guard result == noErr else {
            throw NSError(domain: "Spleen.HotKey", code: Int(result), userInfo: [NSLocalizedDescriptionKey:
                "Couldn't register \(shortcut.label) (macOS \(result)). It may be in use. Choose another shortcut; Spleen remains available from the menu bar."])
        }
        if let reference { UnregisterEventHotKey(reference) }
        reference = replacement; activeID = nextID; registeredShortcut = shortcut
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
