import CoreGraphics
import Testing
@testable import PersonaStack

@Suite @MainActor
struct DesktopLockedControlLocalInputTests {
    @Test func physicalInputRequestsTakeoverAndNeverReachesTheUnlockedDesktop() {
        #expect(decision(.keyDown) == .takeOver)
        #expect(decision(.leftMouseDown) == .takeOver)
        #expect(decision(.keyUp) == .suppress)
        #expect(decision(.mouseMoved) == .suppress)
        #expect(decision(.scrollWheel) == .suppress)
    }

    @Test func ownedDriverAndPrivateSyntheticInputRemainAvailable() {
        #expect(decision(.keyDown, sourcePID: 42) == .allow)
        #expect(decision(.keyDown, state: .privateState, sourcePID: 71) == .allow)
        #expect(decision(.keyDown, sourcePID: 43) == .takeOver)
        #expect(DesktopLockedControlLocalInput.decision(type: .keyDown, sourceState: 1, sourcePID: 0, driverPID: 0) != .allow)
    }

    @Test func disabledTapInvalidatesEvenWhenItsEventLooksLikeDriverInput() {
        #expect(decision(.tapDisabledByTimeout, sourcePID: 42) == .invalidated)
        #expect(decision(.tapDisabledByUserInput) == .invalidated)
    }

    private func decision(_ type: CGEventType, state: CGEventSourceStateID = .hidSystemState,
                          sourcePID: Int64 = 0) -> DesktopLockedControlLocalInput.Decision {
        DesktopLockedControlLocalInput.decision(type: type, sourceState: Int64(state.rawValue),
                                                sourcePID: sourcePID, driverPID: 42)
    }
}
