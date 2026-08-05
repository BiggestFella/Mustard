import XCTest
@testable import MustardKit

/// Voice Setup permission aggregation (Voice Core Task 6, BAK-280).
/// The five capabilities are independent by design: changing one grant must
/// never move another, and each routes to its exact System Settings pane.
final class VoicePermissionStatusTests: XCTestCase {

    // MARK: - Defaults

    func testEveryCapabilityStartsNotDetermined() {
        let status = VoicePermissionStatus()
        for capability in VoiceCapability.allCases {
            XCTAssertEqual(status[capability], .notDetermined, "\(capability) should start notDetermined")
        }
    }

    // MARK: - Independence

    func testGrantingOneCapabilityLeavesOthersUntouched() {
        for granted in VoiceCapability.allCases {
            var status = VoicePermissionStatus()
            status[granted] = .granted
            for other in VoiceCapability.allCases where other != granted {
                XCTAssertEqual(status[other], .notDetermined, "granting \(granted) must not move \(other)")
            }
        }
    }

    func testDenyingOneCapabilityLeavesOthersUntouched() {
        for denied in VoiceCapability.allCases {
            var status = VoicePermissionStatus()
            status[denied] = .denied
            for other in VoiceCapability.allCases where other != denied {
                XCTAssertEqual(status[other], .notDetermined, "denying \(denied) must not move \(other)")
            }
        }
    }

    func testSubscriptReadsBackTheStateItWrote() {
        var status = VoicePermissionStatus()
        for (index, capability) in VoiceCapability.allCases.enumerated() {
            let state: GrantState = index.isMultiple(of: 2) ? .granted : .restricted
            status[capability] = state
            XCTAssertEqual(status[capability], state)
        }
    }

    // MARK: - Settings routes (spec: "a route to the appropriate System Settings pane")

    func testMicrophoneRoutesToMicrophonePane() {
        XCTAssertEqual(
            VoiceCapability.microphone.settingsPane.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    func testSpeechRoutesToSpeechRecognitionPane() {
        XCTAssertEqual(
            VoiceCapability.speech.settingsPane.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        )
    }

    func testAccessibilityRoutesToAccessibilityPane() {
        XCTAssertEqual(
            VoiceCapability.accessibility.settingsPane.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testSystemAudioRoutesToScreenCapturePane() {
        XCTAssertEqual(
            VoiceCapability.systemAudio.settingsPane.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testCalendarRoutesToCalendarsPane() {
        XCTAssertEqual(
            VoiceCapability.calendar.settingsPane.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        )
    }

    // MARK: - Row action (the one decision the setup surface makes per row)

    func testNotDeterminedOffersRequest() {
        XCTAssertEqual(GrantState.notDetermined.setupAction, .request)
    }

    func testGrantedOffersNoAction() {
        XCTAssertEqual(GrantState.granted.setupAction, .none)
    }

    func testDeniedOffersOpenSettings() {
        XCTAssertEqual(GrantState.denied.setupAction, .openSettings)
    }

    func testRestrictedOffersOpenSettings() {
        XCTAssertEqual(GrantState.restricted.setupAction, .openSettings)
    }

    // MARK: - Display order pins the spec's list

    func testDisplayOrderMatchesSpec() {
        XCTAssertEqual(
            VoiceCapability.allCases,
            [.microphone, .speech, .accessibility, .systemAudio, .calendar]
        )
    }
}
