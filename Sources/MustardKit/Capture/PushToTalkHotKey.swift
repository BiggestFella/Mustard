import Foundation

/// The outcome of claiming the push-to-talk chord (Capture Task 3): another
/// app may already own it, and that must never fail silently — the setup
/// surface shows the failed shortcut and a route to change it.
public enum HotKeyRegistration: Equatable, Sendable {
    case registered
    case conflict(OSStatus)
}

#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// System-wide push-to-talk hotkey (F25 v1, ADR-0011) via Carbon
/// `RegisterEventHotKey` — the one API that delivers both *pressed* and
/// *released* events globally without an Accessibility/Input Monitoring grant
/// (the app is ad-hoc signed, ADR-0004). Default chord: ⌃⌥Space, overridable
/// through UserDefaults (`voiceHotKeyCode` / `voiceHotKeyModifiers`).
@MainActor
public final class PushToTalkHotKey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private let keyCode: UInt32
    private let modifiers: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = {
        "MSTD".utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }()
    private static let hotKeyID: UInt32 = 1

    public init(
        keyCode: UInt32 = UInt32(UserDefaults.standard.object(forKey: "voiceHotKeyCode") as? Int ?? kVK_Space),
        modifiers: UInt32 = UInt32(UserDefaults.standard.object(forKey: "voiceHotKeyModifiers") as? Int ?? (controlKey | optionKey))
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Install the Carbon handler and claim the chord. Safe to call repeatedly.
    /// A chord another app already owns is reported as `.conflict` — never
    /// silently (the rest of Mustard is unaffected either way).
    @discardableResult
    public func register() -> HotKeyRegistration {
        guard hotKeyRef == nil else { return .registered }
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // The C callback can't capture context — it gets `self` back via userData.
        // Carbon dispatches on the main event loop; hop through the main queue to
        // re-enter MainActor isolation without assuming it.
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                guard hkID.signature == PushToTalkHotKey.signature,
                      hkID.id == PushToTalkHotKey.hotKeyID else { return noErr }
                let kind = GetEventKind(event)
                let owner = Unmanaged<PushToTalkHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) { owner.onPress?() }
                    if kind == UInt32(kEventHotKeyReleased) { owner.onRelease?() }
                }
                return noErr
            },
            2, &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr, hotKeyRef != nil else {
            hotKeyRef = nil
            return .conflict(status)
        }
        return .registered
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
#endif
