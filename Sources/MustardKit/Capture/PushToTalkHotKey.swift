import Foundation
import os

private let hotKeyLog = Logger(subsystem: "com.cavehole.mustard", category: "hotkey")

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

/// A snapshot of the physically-held keys for one chord.
public struct HotKeyChordState: Equatable, Sendable {
    public var keyDown: Bool
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool

    public init(
        keyDown: Bool, control: Bool = false, option: Bool = false,
        shift: Bool = false, command: Bool = false
    ) {
        self.keyDown = keyDown
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }
}

/// Whether a push-to-talk chord is still held. Carbon only delivers
/// `kEventHotKeyReleased` reliably while the modifiers are still down, so
/// lifting Control/Option before the key strands a capture in "Listening…"
/// with a live microphone and no way out. The hold is therefore decided from
/// physical key state — pure, so both release orders are unit-tested.
public enum HotKeyHold {
    /// Held only while the key AND every modifier the chord requires are
    /// down. Extra modifiers are tolerated: a stray Shift never cancels.
    public static func isHeld(_ state: HotKeyChordState, carbonModifiers: UInt32) -> Bool {
        guard state.keyDown else { return false }
        // Carbon masks (Events.h): cmdKey 0x100, shiftKey 0x200,
        // optionKey 0x800, controlKey 0x1000.
        let required: [(UInt32, Bool)] = [
            (0x1000, state.control),
            (0x0800, state.option),
            (0x0200, state.shift),
            (0x0100, state.command),
        ]
        return required.allSatisfy { mask, isDown in
            carbonModifiers & mask == 0 || isDown
        }
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
    /// One hold at a time; guards double-firing between the Carbon release
    /// event and the physical-state watchdog.
    private var isHolding = false
    private var holdWatchdog: Task<Void, Never>?
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
                    if kind == UInt32(kEventHotKeyPressed) { owner.beginHold() }
                    if kind == UInt32(kEventHotKeyReleased) { owner.endHold() }
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

    // MARK: - Hold lifecycle

    /// Begin a hold (Carbon press). Re-entrant presses while already holding
    /// are ignored — the watchdog below is what ends a hold.
    func beginHold() {
        hotKeyLog.notice("press id=\(self.id, privacy: .public) alreadyHolding=\(self.isHolding, privacy: .public)")
        guard !isHolding else { return }
        isHolding = true
        onPress?()
        startHoldWatchdog()
    }

    /// End a hold exactly once, whichever arrives first: Carbon's release
    /// event or the watchdog noticing the chord is physically up.
    func endHold() {
        hotKeyLog.notice("release id=\(self.id, privacy: .public) wasHolding=\(self.isHolding, privacy: .public)")
        guard isHolding else { return }
        isHolding = false
        holdWatchdog?.cancel()
        holdWatchdog = nil
        onRelease?()
    }

    /// Carbon drops `kEventHotKeyReleased` when the modifiers go up before
    /// the key, which would strand the capture with a live microphone. Poll
    /// the physical chord so the release order simply doesn't matter. These
    /// are plain state reads (no event tap) — no Accessibility or Input
    /// Monitoring grant is involved, which is why Carbon was chosen in the
    /// first place (ADR-0011).
    private func startHoldWatchdog() {
        holdWatchdog?.cancel()
        holdWatchdog = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(70))
                guard let self, self.isHolding else { return }
                let state = self.physicalChordState()
                let held = HotKeyHold.isHeld(state, carbonModifiers: self.modifiers)
                ticks += 1
                if ticks == 1 || ticks % 14 == 0 || !held {
                    hotKeyLog.notice(
                        "watchdog tick=\(ticks, privacy: .public) held=\(held, privacy: .public) key=\(state.keyDown, privacy: .public) ctrl=\(state.control, privacy: .public) opt=\(state.option, privacy: .public)")
                }
                guard !held else { continue }
                self.endHold()
                return
            }
            hotKeyLog.notice("watchdog loop exited")
        }
    }

    private func physicalChordState() -> HotKeyChordState {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return HotKeyChordState(
            keyDown: CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)),
            control: flags.contains(.maskControl),
            option: flags.contains(.maskAlternate),
            shift: flags.contains(.maskShift),
            command: flags.contains(.maskCommand))
    }

    public func unregister() {
        holdWatchdog?.cancel()
        holdWatchdog = nil
        isHolding = false
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
#endif
