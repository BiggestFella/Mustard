import Foundation

/// One TCC-style grant, framework-independent (Voice Core Task 6). `restricted`
/// (parental controls / MDM) is distinct from `denied` in what the OS reports,
/// but both route the user to System Settings — Mustard cannot re-prompt either.
public enum GrantState: String, Equatable, Sendable, Codable {
    case notDetermined, granted, denied, restricted

    /// What the Voice Setup row offers: only a never-asked grant may prompt
    /// in-app; anything refused can only be fixed in System Settings.
    public var setupAction: VoiceSetupAction {
        switch self {
        case .notDetermined: .request
        case .granted: .none
        case .denied, .restricted: .openSettings
        }
    }
}

/// What the Voice Setup row offers for a grant state.
public enum VoiceSetupAction: Equatable, Sendable {
    case request
    case openSettings
    case none
}

/// The five independent capabilities the Voice Setup surface reports, in the
/// spec's display order. Each knows the exact System Settings pane that fixes
/// it, so a denial always comes with a route (spec §Permissions).
public enum VoiceCapability: String, CaseIterable, Identifiable, Equatable, Sendable {
    case microphone, speech, accessibility, systemAudio, calendar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        case .accessibility: "Accessibility"
        case .systemAudio: "Screen & System Audio Recording"
        case .calendar: "Calendar"
        }
    }

    /// Which feature the grant powers — shown so a denial reads as "this one
    /// feature degrades", never as "voice is broken".
    public var explanation: String {
        switch self {
        case .microphone: "Hear you during push-to-talk capture, dictation, and meetings."
        case .speech: "Transcribe what you say on this Mac. Audio never leaves the device."
        case .accessibility: "Insert dictated text into other apps at the cursor."
        case .systemAudio: "Record the other side of a meeting playing through this Mac."
        case .calendar: "Suggest starting a recording when a meeting begins."
        }
    }

    /// Deep link to the System Settings privacy pane for this capability.
    public var settingsPane: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(paneAnchor)")!
    }

    private var paneAnchor: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .accessibility: "Privacy_Accessibility"
        case .systemAudio: "Privacy_ScreenCapture"
        case .calendar: "Privacy_Calendars"
        }
    }
}

/// Aggregated setup state. Fields are independent by design: a denial degrades
/// only the feature that needs it (spec §Permissions), so nothing here derives
/// one grant from another or summarises them into a single "voice is on" flag.
public struct VoicePermissionStatus: Equatable, Sendable {
    public var microphone: GrantState
    public var speech: GrantState
    public var accessibility: GrantState
    public var systemAudio: GrantState
    public var calendar: GrantState

    public init(
        microphone: GrantState = .notDetermined,
        speech: GrantState = .notDetermined,
        accessibility: GrantState = .notDetermined,
        systemAudio: GrantState = .notDetermined,
        calendar: GrantState = .notDetermined
    ) {
        self.microphone = microphone
        self.speech = speech
        self.accessibility = accessibility
        self.systemAudio = systemAudio
        self.calendar = calendar
    }

    public subscript(_ capability: VoiceCapability) -> GrantState {
        get {
            switch capability {
            case .microphone: microphone
            case .speech: speech
            case .accessibility: accessibility
            case .systemAudio: systemAudio
            case .calendar: calendar
            }
        }
        set {
            switch capability {
            case .microphone: microphone = newValue
            case .speech: speech = newValue
            case .accessibility: accessibility = newValue
            case .systemAudio: systemAudio = newValue
            case .calendar: calendar = newValue
            }
        }
    }
}
