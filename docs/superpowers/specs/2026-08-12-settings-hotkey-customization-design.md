# Settings consolidation + customizable hotkeys — design

**Date:** 2026-08-12
**Status:** Approved by Leon (design presented in chat; picks: expand in-app Settings,
all hotkeys customizable, key-recorder UX, bare Agent console)
**Branch:** `claude/settings-hotkey-customization-eff415`

## Problem

The Agent console doubles as a settings page: vault path, meeting-notes vault, trust
level, auto-open-source toggle, the sweep-projects list, and the Google Calendar OAuth
fields all live in its header/source rows (`AgentConsoleView.swift`), while a separate
`SettingsView` (sidebar ⚙, BAK-133) duplicates the trust picker and embeds the same
`SourceSettingsView`. Configuration is scattered and duplicated, and the console's
triage surface is buried under config chrome.

Separately, every hotkey is fixed. The three global Carbon hotkeys (⌃⌥Space
push-to-talk, ⌃⌥D dictation, ⌃⌥R rewrite) already read overrides from UserDefaults but
have no UI — the only remedy for a chord conflict is the Voice Setup copy telling you
to edit `defaults` and relaunch. The five in-app SwiftUI shortcuts (⌘⇧H hover, ⌘⇧N
notch, ⌘K command bar, ⌘⇧S source inspector, ⌘⇧F note search) are hardcoded.

## Goals

1. One settings home: the existing in-app `SettingsView` grows into sections and takes
   over **all** configuration currently on the Agent console.
2. The Agent console becomes pure triage (recommendations + runs) with a gear that
   jumps to Settings.
3. All eight hotkeys are user-customizable via a System Settings-style key recorder,
   with inline conflict feedback and per-row reset to default.

## Non-goals (YAGNI)

- No native macOS `Settings` scene / ⌘, window (Leon chose in-app).
- No new SwiftData settings model — UserDefaults idioms stay (ADR-0001 defers this).
- No customization of local, view-scoped shortcuts (⌘Return commit, ⌘S save, etc.).
- No import/export of settings.

## Design

### 1. Settings screen structure

`SettingsView` stays a single calm scroll (max width 640, Theme tokens), reorganized
into sections in this order:

1. **SOURCES & AGENT** — vault path picker (`@AppStorage("vaultPath")`), meeting-notes
   vault picker (`meetingVaultPath`, shows `agent.lastMeetingSummary`), the
   `SourceSettingsView` projects list (enable/interval/remove/add — unchanged,
   relocated), a **Sweep now** button (`agent.sweep(vaultPath:)`) with last-swept info,
   the trust segmented control (existing — keeps the two-step write via
   `agent.applyTrust`), and the **Auto-open source** toggle
   (`@AppStorage("autoOpenSourceOnSelect")` — key unchanged; the console keeps reading
   it, only the toggle UI moves).
2. **CALENDAR** — the Google Calendar OAuth fields, moved out of `SourceSettingsView`
   into their own section (content unchanged: Keychain-backed credentials,
   Connect/Refresh/Disconnect).
3. **VOICE** — existing "Voice Setup…" row (unchanged).
4. **HOTKEYS** — new; see §3.

The copy-pasted section-header style (`.font(.system(size: 10, weight:
.semibold)).tracking(0.06)`) is promoted to a `Theme.Fonts.sectionHeader` token and
used by the new sections (existing call sites migrate opportunistically where touched).

### 2. Agent console strip-down

`AgentConsoleView` loses: the Auto-open source toggle, `sourceRow` (vault picker,
Sweep button, trust picker, blurb), `meetingSourceRow`, and the embedded
`SourceSettingsView`. What remains is the triage master/detail (recommendations, runs,
Needs You / Needs Review flows).

A gear button in the console header navigates to Settings. Screen state lives in
`RootView`, so the console gets an `onOpenSettings: (() -> Void)?` closure (same
pattern as `SettingsView.onVoiceSetup`); `RootView` passes `{ screen = .settings }`.

Sweep remains reachable from Settings (Sweep now) and the ⌘K command bar (`.sweep`
command — already exists). The comment in `SettingsView.swift:4-7` about trust being
intentionally duplicated is updated: Settings becomes the *only* trust surface.

### 3. Hotkey model — `Logic/HotKeyBindings.swift` (pure, TDD)

A new pure unit following the `BoardSettings` injected-`UserDefaults` pattern:

- **`HotKeyChord`** value type: `keyCode: UInt32` + `carbonModifiers: UInt32`
  (Carbon masks are already the stored representation for the global three; the
  in-app five adopt the same representation for uniformity). `Codable`/`Equatable`.
- **`HotKeyAction`** enum — the registry: `.pushToTalk, .dictation, .rewrite`
  (global) and `.hover, .notch, .commandBar, .sourceInspector, .noteSearch` (in-app),
  each with a display label, a scope (`.global`/`.inApp`), a default chord, and its
  UserDefaults key pair.
- **Persistence keys.** The global three keep their existing keys —
  `voiceHotKeyCode/voiceHotKeyModifiers`, `dictationHotKeyCode/…`,
  `rewriteHotKeyCode/…` — so existing manual overrides survive with no migration.
  The in-app five get `hotkey.<action>.code` / `hotkey.<action>.modifiers`, absent
  meaning default.
- **`HotKeyBindings`** struct: `chord(for:)`, `set(_:for:)`, `reset(for:)`,
  `resetAll()`, against an injected `UserDefaults`.
- **Display formatting.** The existing `HotKeyChord.description` formatter's
  three-entry key table grows into a full macOS key-name table (letters, digits,
  space, arrows, return/tab/escape/delete, F-keys, common punctuation), keeping the
  `key #N` fallback.
- **Validation** (pure): a chord must contain ≥1 modifier and a real key (modifier-only
  chords rejected — required for both scopes; an unmodified letter would fire while
  typing).
- **Conflict detection** (pure): assigning a chord already held by another action in
  the registry is rejected, regardless of scope (a global and an in-app action sharing
  a chord would shadow each other confusingly).
- **`KeyboardShortcut` mapping** (pure where possible): keyCode → `KeyEquivalent` table
  + carbonModifiers → `EventModifiers`, for the in-app five. Keys with no
  `KeyEquivalent` representation are rejected by the recorder for in-app actions;
  global (Carbon) actions accept any keyCode.

### 4. Recorder — `Views/HotKeyRecorderView`

One field per hotkey row: click to arm, press the chord, done. While armed, an
`NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])` captures the
event; **Esc cancels**, **⌫ resets to default**. The NSEvent→`HotKeyChord` mapping
(`NSEvent.ModifierFlags` → Carbon masks) and the accept/reject decision are pure
functions in the Logic unit (testable); the view only arms/disarms the monitor and
renders. The monitor is removed on disarm/disappear.

Row layout: action label · current chord (formatted) · recorder field · reset button ·
inline status. Conflict/validation rejections show inline in `Theme.Palette.error`
("already used by Hover panel", "add a modifier"). A **Reset all** row sits at the
section's foot.

### 5. Applying changes

- **In-app five (live).** A small `@Observable HotKeyBindingsStore` (wraps
  `HotKeyBindings`, published chords) is created in `MustardApp` and injected via
  Environment. The `.keyboardShortcut` call sites in `MustardApp.swift` (⌘⇧H/⌘⇧N
  command menu) and `RootView.swift` (⌘K/⌘⇧S/⌘⇧F hidden buttons) read
  `store.shortcut(for:)` instead of literals — menus and shortcuts update live.
- **Global three (live rebind).** `PushToTalkHotKey` and `RewriteHotKey` gain
  `rebind(keyCode:modifiers:)` = unregister + re-register with the new chord.
  Push-to-talk/dictation rebind first ends any active hold through the normal
  release path (the capture commits — transcript never lost), then re-registers;
  `unregister()` alone would clear the hold flag without firing `onRelease`. The
  store's `applyGlobal` closure routes binding changes into the rebinds.
- **Registration status.** Rebind results land on the existing
  `PushToTalkHotKey.registrationBoard`; `RewriteHotKey` starts publishing there too
  (closing today's gap where a ⌃⌥R conflict is invisible). The Hotkeys section renders
  each global row's registration state — an OS-level rejection (chord taken by another
  app) keeps the saved chord but shows a red "in use by another app" note with Reset.
- **Voice Setup copy.** The SHORTCUTS conflict text in `VoiceSetupView` (edit
  `defaults`, relaunch) now points to Settings → Hotkeys.

### 6. Error handling

- Recorder rejections (no modifier, unmappable key for in-app, duplicate) never write;
  the field shows the reason and stays on the old chord.
- OS registration failure on rebind: chord persists, row shows the conflict, user can
  Reset or pick another chord. No silent fallback.
- Malformed/unknown stored values (e.g. hand-edited defaults): `chord(for:)` falls
  back to the action's default.

### 7. Testing

Pure units TDD'd, one XCTest file per unit, mirroring `BoardSettingsTests` (per-test
`UserDefaults(suiteName:)`) and the existing `HotKeyChordTests`:

- `HotKeyBindingsTests` — defaults for all 8, round-trip, legacy-key compat (a
  pre-existing `voiceHotKeyCode` override is honored), reset/resetAll, malformed
  values fall back.
- `HotKeyChordTests` (extended) — key-name table coverage, fallback.
- `HotKeyRecorderLogicTests` — NSEvent flag→Carbon mapping, Esc/⌫ semantics,
  accept/reject rules (modifier required, in-app mappability).
- `HotKeyConflictTests` — duplicate detection across the registry, cross-scope.
- `KeyboardShortcutMappingTests` — keyCode→KeyEquivalent/EventModifiers.

Views (Settings sections, recorder, console strip-down) are verified by `swift build`
+ Leon's eye — the console header, the Hotkeys section, and one live rebind
(e.g. change ⌘⇧H, hit the new chord) are the things to look at.

### 8. Risks / notes

- **⌘K etc. as hidden background buttons:** dynamic `KeyboardShortcut` on those
  buttons re-evaluates with the observable store; no NSEvent monitors needed.
- **Carbon re-registration mid-session** is new behavior; the deactivate/reactivate
  path reuses the existing activate/deactivate code (BAK-290's dispatch rules are
  untouched — `HotKeyDispatch.decide` still sees per-id events).
- **Space in SwiftUI** maps to `KeyEquivalent(" ")` — covered by the mapping table
  should someone assign Space to an in-app action.
- The Agent console loses its at-a-glance trust pill; trust changes become a Settings
  trip. Accepted (Leon picked bare console).
