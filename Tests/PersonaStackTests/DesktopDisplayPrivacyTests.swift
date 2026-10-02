import Foundation
@testable import PersonaStackCore
import Testing

@Suite
struct DesktopDisplayPrivacyTests {
    @Test @MainActor func concealAndRestoreEveryDisplayByUUID() throws {
        let displays = [display("display-a"), display("display-b")]
        let original = ["display-a": table(0.1), "display-b": table(0.4)]
        let fake = StrictDisplayGammaAdapter(displays: displays, tables: original)
        let controller = controller(for: fake)

        try controller.concealAllDisplays()
        #expect(fake.tables["display-a"] == blackTable())
        #expect(fake.tables["display-b"] == blackTable())
        #expect(fake.observesChanges)

        try controller.restoreDisplays()
        #expect(fake.tables == original)
        #expect(!fake.observesChanges)
        #expect(fake.resolvedUUIDs.contains("display-a"))
        #expect(fake.resolvedUUIDs.contains("display-b"))
    }

    @Test @MainActor func unsupportedDisplayFailsBeforeChangingAnyGamma() throws {
        let original = ["display-a": table(0.1)]
        let fake = StrictDisplayGammaAdapter(
            displays: [display("display-a"), display("unsupported", capacity: 0)],
            tables: original)
        var invalidations: [DesktopDisplayPrivacyInvalidation] = []
        let controller = DesktopDisplayPrivacyController(adapter: fake,
                                                         sessionIsActuallyLocked: { fake.sessionLocked }) {
            invalidations.append($0)
        }

        #expect(throws: DesktopDisplayPrivacyError.self) {
            try controller.concealAllDisplays()
        }

        #expect(fake.tables == original)
        #expect(fake.setCalls.isEmpty)
        #expect(invalidations == [.activationFailed])
    }

    @Test @MainActor func refusesToChangeGammaWithoutObservedLock() throws {
        let original = ["display-a": table(0.1)]
        let fake = StrictDisplayGammaAdapter(displays: [display("display-a")], tables: original)
        fake.sessionLocked = false
        let controller = controller(for: fake)

        #expect(throws: DesktopDisplayPrivacyError.sessionNotLocked) {
            try controller.concealAllDisplays()
        }

        #expect(fake.tables == original)
        #expect(fake.setCalls.isEmpty)
        #expect(!fake.observesChanges)
    }

    @Test @MainActor func partialBlackoutFailureRestoresEarlierDisplays() throws {
        let original = ["display-a": table(0.1), "display-b": table(0.4)]
        let fake = StrictDisplayGammaAdapter(
            displays: [display("display-a"), display("display-b")],
            tables: original)
        fake.failBlackWriteForUUID = "display-b"
        var invalidations: [DesktopDisplayPrivacyInvalidation] = []
        let controller = DesktopDisplayPrivacyController(adapter: fake,
                                                         sessionIsActuallyLocked: { fake.sessionLocked }) {
            invalidations.append($0)
        }

        #expect(throws: DesktopDisplayPrivacyError.self) {
            try controller.concealAllDisplays()
        }

        #expect(fake.tables == original)
        #expect(invalidations == [.activationFailed])
        #expect(!fake.observesChanges)
    }

    @Test @MainActor func nonBlackReadbackRollsBackAndInvalidatesOwner() throws {
        let original = ["display-a": table(0.1)]
        let fake = StrictDisplayGammaAdapter(displays: [display("display-a")], tables: original)
        fake.nonBlackReadbackForUUID = "display-a"
        var invalidations: [DesktopDisplayPrivacyInvalidation] = []
        let controller = DesktopDisplayPrivacyController(adapter: fake,
                                                         sessionIsActuallyLocked: { fake.sessionLocked }) {
            invalidations.append($0)
        }

        #expect(throws: DesktopDisplayPrivacyError.blackGammaReadbackFailed("display-a")) {
            try controller.concealAllDisplays()
        }

        #expect(fake.tables == original)
        #expect(invalidations == [.activationFailed])
    }

    @Test @MainActor func displayChangeNotifiesRuntimeBeforeRestoringSnapshot() async throws {
        let original = ["display-a": table(0.1)]
        let fake = StrictDisplayGammaAdapter(displays: [display("display-a")], tables: original)
        var invalidations: [DesktopDisplayPrivacyInvalidation] = []
        let controller = DesktopDisplayPrivacyController(adapter: fake,
                                                         sessionIsActuallyLocked: { fake.sessionLocked }) {
            invalidations.append($0)
        }
        try controller.concealAllDisplays()

        fake.addDisplay(display("display-b"), initialTable: table(0.7))
        fake.sessionLocked = false
        fake.emitDisplayChange()
        await Task.yield()

        #expect(invalidations == [.displayConfigurationChanged])
        #expect(fake.tables["display-a"] == blackTable())
        #expect(fake.tables["display-b"] == table(0.7))
        #expect(fake.observesChanges)

        fake.sessionLocked = true
        try controller.restoreDisplays()
        #expect(fake.tables["display-a"] == original["display-a"])
        #expect(!fake.observesChanges)
    }

    @Test @MainActor func removedDisplayKeepsSnapshotForLaterRestoreRetry() async throws {
        let original = ["display-a": table(0.1)]
        let fake = StrictDisplayGammaAdapter(displays: [display("display-a")], tables: original)
        var invalidations: [DesktopDisplayPrivacyInvalidation] = []
        let controller = DesktopDisplayPrivacyController(adapter: fake,
                                                         sessionIsActuallyLocked: { fake.sessionLocked }) {
            invalidations.append($0)
        }
        try controller.concealAllDisplays()

        fake.sessionLocked = false
        fake.removeDisplay("display-a")
        fake.emitDisplayChange()
        await Task.yield()
        #expect(invalidations == [.displayConfigurationChanged])
        #expect(fake.observesChanges)
        #expect(throws: DesktopDisplayPrivacyError.sessionNotLocked) {
            try controller.restoreDisplays()
        }
        #expect(invalidations == [.displayConfigurationChanged])

        fake.sessionLocked = true
        #expect(throws: DesktopDisplayPrivacyError.self) { try controller.restoreDisplays() }
        #expect(invalidations == [.displayConfigurationChanged, .restorationFailed])

        fake.addDisplay(display("display-a"), initialTable: blackTable())
        try controller.restoreDisplays()
        #expect(fake.tables["display-a"] == original["display-a"])
        #expect(!fake.observesChanges)
    }

    private func display(_ uuid: String, capacity: Int = 4) -> DesktopDisplayDescriptor {
        DesktopDisplayDescriptor(uuid: uuid, gammaCapacity: capacity)
    }

    private func table(_ value: Float) -> DesktopDisplayGammaTable {
        DesktopDisplayGammaTable(red: [value, value + 0.1, value + 0.2, value + 0.3],
                                 green: [value + 0.3, value + 0.2, value + 0.1, value],
                                 blue: [value, value + 0.2, value + 0.1, value + 0.3])
    }

    private func blackTable() -> DesktopDisplayGammaTable {
        DesktopDisplayGammaTable(red: [0, 0, 0, 0], green: [0, 0, 0, 0], blue: [0, 0, 0, 0])
    }

    @MainActor
    private func controller(for adapter: StrictDisplayGammaAdapter) -> DesktopDisplayPrivacyController {
        DesktopDisplayPrivacyController(adapter: adapter,
                                        sessionIsActuallyLocked: { adapter.sessionLocked })
    }
}

@MainActor
private final class StrictDisplayGammaAdapter: DesktopDisplayGammaAdapting {
    private(set) var displays: [DesktopDisplayDescriptor]
    private(set) var tables: [String: DesktopDisplayGammaTable]
    private(set) var setCalls: [String] = []
    private(set) var resolvedUUIDs: [String] = []
    private(set) var observesChanges = false
    var sessionLocked = true
    var failBlackWriteForUUID: String?
    var nonBlackReadbackForUUID: String?
    private var changeHandler: (@Sendable () -> Void)?

    init(displays: [DesktopDisplayDescriptor], tables: [String: DesktopDisplayGammaTable]) {
        self.displays = displays
        self.tables = tables
    }

    func onlineDisplays() throws -> [DesktopDisplayDescriptor] { displays }

    func readGammaTable(displayUUID: String) throws -> DesktopDisplayGammaTable {
        resolvedUUIDs.append(displayUUID)
        guard displays.contains(where: { $0.uuid == displayUUID }),
              let table = tables[displayUUID] else {
            throw DesktopDisplayPrivacyError.unsupportedDisplay(displayUUID)
        }
        let isBlack = (table.red + table.green + table.blue).allSatisfy { $0 == 0 }
        if isBlack, nonBlackReadbackForUUID == displayUUID {
            return DesktopDisplayGammaTable(red: [0.01, 0, 0, 0],
                                            green: [0, 0, 0, 0],
                                            blue: [0, 0, 0, 0])
        }
        return table
    }

    func setGammaTable(_ table: DesktopDisplayGammaTable, displayUUID: String) throws {
        setCalls.append(displayUUID)
        guard let display = displays.first(where: { $0.uuid == displayUUID }),
              table.sampleCount > 0, table.sampleCount <= display.gammaCapacity,
              table.green.count == table.sampleCount, table.blue.count == table.sampleCount else {
            throw DesktopDisplayPrivacyError.unsupportedDisplay(displayUUID)
        }
        let isBlack = (table.red + table.green + table.blue).allSatisfy { $0 == 0 }
        if isBlack, failBlackWriteForUUID == displayUUID {
            failBlackWriteForUUID = nil
            throw DesktopDisplayPrivacyError.operationFailed(displayUUID)
        }
        tables[displayUUID] = table
    }

    func setDisplayChangeHandler(_ handler: (@Sendable () -> Void)?) throws {
        changeHandler = handler
        observesChanges = handler != nil
    }

    func emitDisplayChange() { changeHandler?() }

    func addDisplay(_ display: DesktopDisplayDescriptor,
                    initialTable: DesktopDisplayGammaTable) {
        displays.append(display)
        tables[display.uuid] = initialTable
    }

    func removeDisplay(_ uuid: String) {
        displays.removeAll { $0.uuid == uuid }
    }
}
