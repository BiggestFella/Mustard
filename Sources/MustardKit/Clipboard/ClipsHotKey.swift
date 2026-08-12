#if os(macOS)
import Carbon.HIToolbox
import Foundation
import os

/// Boundary instrumentation for the clipboard layer. Same subsystem as the
/// voice/rewrite suites so one predicate follows a whole interaction:
///
///     log stream --predicate 'subsystem == "com.cavehole.mustard"'
///
/// Clip CONTENT is never logged — the whole point of a local clipboard history
/// is that the user's copied text stays on their machine, and a system log is
/// readable by anything running on it.
public enum ClipboardLog {
    public static let logger = Logger(subsystem: "com.cavehole.mustard", category: "clipboard")
}

/// ⌃⌥V, tap semantics: open the notch pinned on Clips. Registered with Carbon
/// `RegisterEventHotKey`, which needs no Accessibility or Input Monitoring
/// grant.
///
/// Three properties are load-bearing, all learned the hard way in the voice
/// suite:
/// 1. The handler MUST fall through (`eventNotHandledErr`) for any hot key that
///    is not ours. A handler returning `noErr` for a foreign chord swallowed
///    ⌃⌥Space system-wide (BAK-290). The decision is the shared, unit-tested
///    `HotKeyDispatch.decide`, not a hand-rolled comparison.
/// 2. This is a PRESSED-only hot key. Carbon delivers `kEventHotKeyReleased`
///    reliably only while the chord's modifiers are still held, so a tap-style
///    action fires on press and never waits for a release.
/// 3. A chord another application already owns is reported as `.conflict`,
///    never silently dropped — same contract as `PushToTalkHotKey`.
///
/// It shares `PushToTalkHotKey`'s "MSTD" signature with a distinct id (capture
/// is 1, dictation 2, rewrite 3, clips 4), which is exactly what
/// `HotKeyDispatch` disambiguates on.
@MainActor
public final class ClipsHotKey {
    /// Fired on ⌃⌥V press, on the main queue.
    public var onPress: (() -> Void)?

    /// The last registration result, so a conflict can be surfaced rather than
    /// discovered by a key that mysteriously does nothing.
    public private(set) var registration: HotKeyRegistration?

    private let id: UInt32
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = {
        "MSTD".utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }()

    public init(
        id: UInt32 = 4,
        keyCode: UInt32 = UInt32(
            UserDefaults.standard.object(forKey: "clipsHotKeyCode") as? Int ?? kVK_ANSI_V),
        modifiers: UInt32 = UInt32(
            UserDefaults.standard.object(forKey: "clipsHotKeyModifiers") as? Int
                ?? (controlKey | optionKey))
    ) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Install the Carbon handler and claim the chord. Safe to call repeatedly.
    @discardableResult
    public func register() -> HotKeyRegistration {
        guard hotKeyRef == nil else { return .registered }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // The C callback can't capture context — it gets `self` back via
        // userData. Carbon dispatches on the main event loop; hop through the
        // main queue to re-enter MainActor isolation without assuming it.
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
                let owner = Unmanaged<ClipsHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard HotKeyDispatch.decide(
                    eventSignature: hkID.signature, eventID: hkID.id,
                    expectedSignature: ClipsHotKey.signature, ownerID: owner.id
                ) == .handle else { return fallThrough }
                DispatchQueue.main.async { owner.fire() }
                return noErr
            },
            1, &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        let result: HotKeyRegistration
        if status == noErr, hotKeyRef != nil {
            result = .registered
        } else {
            hotKeyRef = nil
            result = .conflict(status)
        }
        registration = result
        ClipboardLog.logger.notice(
            "hotkey chord=\(HotKeyChord.description(keyCode: self.keyCode, modifiers: self.modifiers), privacy: .public) registration=\(String(describing: result), privacy: .public)")
        return result
    }

    func fire() {
        ClipboardLog.logger.notice("hotkey press id=\(self.id, privacy: .public)")
        onPress?()
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        registration = nil
    }
}
#endif
