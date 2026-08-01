import Foundation

/// The outcome of claiming the push-to-talk chord (Capture Task 3): another
/// app may already own it, and that must never fail silently — the setup
/// surface shows the failed shortcut and a route to change it.
public enum HotKeyRegistration: Equatable, Sendable {
    case registered
    case conflict(OSStatus)
}

/// What one Carbon hotkey handler must do with one hotkey event. Every
/// handler installed on the dispatcher target receives EVERY hotkey event, and
/// Carbon treats `noErr` as "handled — stop propagating": a handler that
/// claims an event it doesn't own silently kills the other chord. Pure so the
/// rule is unit-tested rather than eyeballed.
public enum HotKeyDispatch: Equatable, Sendable {
    /// This instance owns the chord: fire its callbacks and stop propagation.
    case handle
    /// Another instance owns it — MUST fall through to the next handler.
    case passToNextHandler

    public static func decide(
        eventSignature: OSType,
        eventID: UInt32,
        expectedSignature: OSType,
        ownerID: UInt32
    ) -> HotKeyDispatch {
        (eventSignature == expectedSignature && eventID == ownerID)
            ? .handle
            : .passToNextHandler
    }
}

/// Pure chord formatting for the setup surface (raw Carbon values so the
/// formatter stays platform-free): "⌃⌥Space", "⌃⌥D", …
public enum HotKeyChord {
    /// Carbon modifier masks (Events.h): cmdKey/shiftKey/optionKey/controlKey.
    private static let masks: [(UInt32, String)] = [
        (0x1000, "⌃"), (0x800, "⌥"), (0x200, "⇧"), (0x100, "⌘"),
    ]
    /// The key codes Mustard's chords actually use, plus a readable fallback.
    private static let keyNames: [UInt32: String] = [49: "Space", 2: "D"]

    public static func description(keyCode: UInt32, modifiers: UInt32) -> String {
        let mods = masks.filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return mods + (keyNames[keyCode] ?? "key #\(keyCode)")
    }
}

#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// System-wide push-to-talk hotkey (ADR-0011) via Carbon
/// `RegisterEventHotKey` — the one API that delivers both *pressed* and
/// *released* events globally without an Accessibility/Input Monitoring grant
/// (the app is ad-hoc signed, ADR-0004). One instance per chord, each with a
/// distinct `id`: task capture is ID 1 / ⌃⌥Space, dictation is ID 2 / ⌃⌥D,
/// both overridable through UserDefaults.
@MainActor
public final class PushToTalkHotKey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = {
        "MSTD".utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    /// Registration outcomes by purpose, read by Voice Setup's SHORTCUTS
    /// section — a chord conflict must be visible somewhere, never silent.
    public private(set) static var registrationBoard: [String: (chord: String, registration: HotKeyRegistration)] = [:]

    public init(
        id: UInt32 = 1,
        keyCode: UInt32 = UInt32(UserDefaults.standard.object(forKey: "voiceHotKeyCode") as? Int ?? kVK_Space),
        modifiers: UInt32 = UInt32(UserDefaults.standard.object(forKey: "voiceHotKeyModifiers") as? Int ?? (controlKey | optionKey))
    ) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The task-capture chord (⌃⌥Space by default).
    public static func capture() -> PushToTalkHotKey {
        PushToTalkHotKey(id: 1)
    }

    /// The system-wide dictation chord (⌃⌥D by default).
    public static func dictation() -> PushToTalkHotKey {
        PushToTalkHotKey(
            id: 2,
            keyCode: UInt32(UserDefaults.standard.object(forKey: "dictationHotKeyCode") as? Int ?? kVK_ANSI_D),
            modifiers: UInt32(UserDefaults.standard.object(forKey: "dictationHotKeyModifiers") as? Int ?? (controlKey | optionKey)))
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
                let fallThrough = OSStatus(eventNotHandledErr)
                guard let event, let userData else { return fallThrough }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                let kind = GetEventKind(event)
                let owner = Unmanaged<PushToTalkHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Every handler on the dispatcher target sees EVERY hotkey
                // event, and `noErr` means "handled — stop propagating". A
                // foreign chord MUST fall through or the instance that owns it
                // never hears its own key (BAK-290 regression: ⌃⌥D's handler
                // silently swallowed ⌃⌥Space).
                guard HotKeyDispatch.decide(
                    eventSignature: hkID.signature, eventID: hkID.id,
                    expectedSignature: PushToTalkHotKey.signature, ownerID: owner.id
                ) == .handle else { return fallThrough }
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) { owner.onPress?() }
                    if kind == UInt32(kEventHotKeyReleased) { owner.onRelease?() }
                }
                return noErr
            },
            2, &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        let result: HotKeyRegistration
        if status == noErr, hotKeyRef != nil {
            result = .registered
        } else {
            hotKeyRef = nil
            result = .conflict(status)
        }
        let purpose = id == 2 ? "Dictation" : "Task capture"
        Self.registrationBoard[purpose] = (
            chord: HotKeyChord.description(keyCode: keyCode, modifiers: modifiers),
            registration: result)
        return result
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
#endif
