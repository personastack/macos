import Darwin
import Foundation
import Testing
@testable import PersonaStack
@testable import PersonaStackCore

private typealias PermissionMount = DesktopVolumePermissionMount

private func permissionMount(_ name: String, id: Int32 = 1, type: String = "apfs",
                             flags: UInt32 = UInt32(MNT_LOCAL | MNT_REMOVABLE)) -> PermissionMount {
    .init(url: URL(fileURLWithPath: "/fake-mounts/\(name)", isDirectory: true),
          fileSystemIDFirst: id, fileSystemIDSecond: 2, fileSystemType: type, flags: flags)
}

@MainActor
private final class VolumePermissionFixture {
    var mounts: [PermissionMount]
    var inventoryFails = false
    var context = "environment-a:presentation-a"
    var selections: [PermissionMount?] = []
    var expectedChecks: [PermissionMount] = []
    var checks: [PermissionMount] = []
    var choices: [(DesktopPermissionID, [PermissionMount])] = []
    var failure: Error?
    var suspendVerification = false
    var pending: [CheckedContinuation<Void, Error>] = []

    init(_ mounts: [PermissionMount]) { self.mounts = mounts }

    lazy var owner = DesktopVolumePermissionCheck(snapshot: { [unowned self] in
        if inventoryFails { throw DesktopVolumePermissionInventoryError.unavailable }
        return mounts
    }, choose: { [unowned self] permission, candidates in
        choices.append((permission, candidates))
        guard !selections.isEmpty else { Issue.record("Unexpected chooser call"); return nil }
        return selections.removeFirst()
    }, verify: { [unowned self] mount in
        checks.append(mount)
        guard !expectedChecks.isEmpty else { Issue.record("Unexpected protected operation"); return }
        #expect(expectedChecks.removeFirst() == mount)
        if suspendVerification { try await withCheckedThrowingContinuation { pending.append($0) } }
        if let failure { throw failure }
    }, contextKey: { [unowned self] in context })

    func setup(_ mount: PermissionMount, permission: DesktopPermissionID = .removableVolumes) async -> DesktopPermissionObservation {
        selections.append(mount)
        expectedChecks.append(mount)
        return await owner.setup(permission)
    }
}

struct DesktopVolumePermissionTests {
    @Test func classifiesOnlySupportedMountedResourceKinds() {
        #expect(permissionMount("usb").applies(to: .removableVolumes))
        #expect(!permissionMount("internal", flags: UInt32(MNT_LOCAL)).applies(to: .removableVolumes))
        for type in ["smbfs", "nfs", "afpfs", "webdav"] {
            let mount = permissionMount(type, type: type, flags: 0)
            #expect(mount.applies(to: .networkVolumes))
            #expect(!mount.applies(to: .removableVolumes))
        }
        for type in ["autofs", "devfs", "volfs", "fdesc", "procfs", "tmpfs"] {
            #expect(!permissionMount(type, type: type, flags: 0).applies(to: .networkVolumes))
        }
        #expect(permissionMount("unknown", type: "unknown", flags: 0).isUnqualifiedNetworkVolume)
        #expect(!permissionMount("local-smb", type: "smbfs").applies(to: .networkVolumes))
        #expect(!permissionMount("usb").applies(to: .desktopFiles))
    }

    @Test @MainActor func unknownNetworkFilesystemCannotBecomeNotNeededOrReceiveAProbe() async {
        let mount = permissionMount("unqualified", type: "unqualifiedfs", flags: 0)
        let fixture = VolumePermissionFixture([mount])
        #expect(fixture.owner.observe(.networkVolumes).state == .unsupported)
        #expect(fixture.owner.observation(for: mount).state == .unsupported)
        fixture.selections.append(mount)
        #expect(await fixture.owner.setup(.networkVolumes).state == .unsupported)
        #expect(fixture.checks.isEmpty)
    }

    @Test @MainActor func passiveInventoryDoesNotSelectOrProbeAndAbsentCategoriesStayNotNeeded() {
        let fixture = VolumePermissionFixture([permissionMount("usb")])
        #expect(fixture.owner.observe(.removableVolumes).state == .checking)
        #expect(fixture.owner.observe(.networkVolumes).state == .notNeeded)
        fixture.mounts = []
        #expect(fixture.owner.observe(.removableVolumes).state == .notNeeded)
        #expect(fixture.choices.isEmpty && fixture.checks.isEmpty)
    }

    @Test @MainActor func everyMountedResourceNeedsItsOwnExplicitSuccessfulCheck() async {
        let first = permissionMount("a")
        let second = permissionMount("b", id: 3)
        let fixture = VolumePermissionFixture([second, first])
        #expect(await fixture.setup(first).state == .checking)
        #expect(fixture.owner.observation(for: first).verified)
        #expect(fixture.owner.observation(for: second).state == .checking)
        #expect(fixture.choices.first?.1 == [first, second])
        #expect(fixture.checks == [first])
        let complete = await fixture.setup(second)
        #expect(complete.state == .ready && complete.verified && complete.requiresVerification)
        #expect(complete.detail.contains("Verified 2 of 2"))
        #expect(fixture.owner.observe(.removableVolumes) == complete)
        #expect(fixture.checks == [first, second] && fixture.expectedChecks.isEmpty)
    }

    @Test @MainActor func oneReadyVolumeCannotHideAnotherDeniedVolume() async {
        let first = permissionMount("a")
        let second = permissionMount("b", id: 3)
        let fixture = VolumePermissionFixture([first, second])
        _ = await fixture.setup(first)
        fixture.failure = DesktopFileSystemError.permissionDenied
        let result = await fixture.setup(second)
        #expect(result.state == .denied && !result.verified)
        #expect(result.detail.contains("Verified 1 of 2"))
        #expect(fixture.owner.observation(for: first).verified)
        #expect(fixture.owner.observation(for: second).state == .denied)
        #expect(fixture.owner.observe(.removableVolumes) == result)
    }

    @Test @MainActor func readOnlyVolumeRequestsOnlyItsDeclaredReadOnlyCheck() async {
        let mount = permissionMount("readonly", flags: UInt32(MNT_LOCAL | MNT_REMOVABLE | MNT_RDONLY))
        let fixture = VolumePermissionFixture([mount])
        #expect(await fixture.setup(mount).state == .ready)
        #expect(fixture.checks == [mount] && fixture.checks[0].isReadOnly)
        let resource = fixture.owner.observation(for: mount)
        #expect(resource.verified && resource.detail.contains("listing this read-only volume"))
        #expect(resource.detail.contains("Writes are unavailable"))
        #expect(!resource.detail.contains("disposable"))
    }

    @Test @MainActor func wrongCategoryOrForgedSelectionHasNoProtectedSideEffects() async {
        let mount = permissionMount("usb")
        let network = permissionMount("network", type: "smbfs", flags: 0)
        let fixture = VolumePermissionFixture([mount, network])
        for rejected in [network, permissionMount("missing", id: 99)] {
            fixture.selections.append(rejected)
            #expect(await fixture.owner.setup(.removableVolumes).state == .failed)
        }
        #expect(fixture.checks.isEmpty)
        #expect(fixture.owner.observe(.removableVolumes).state == .checking)
    }

    @Test @MainActor func cancelledSelectionDoesNotEraseExistingProofOrProbeAnotherResource() async {
        let mount = permissionMount("usb")
        let fixture = VolumePermissionFixture([mount])
        _ = await fixture.setup(mount)
        let prior = fixture.owner.observe(.removableVolumes)
        fixture.selections.append(nil)
        #expect(await fixture.owner.setup(.removableVolumes) == prior)
        #expect(fixture.checks == [mount])
    }

    @Test @MainActor func failedRecheckReplacesPriorSuccessfulProof() async {
        let mount = permissionMount("usb")
        let fixture = VolumePermissionFixture([mount])
        _ = await fixture.setup(mount)
        fixture.failure = DesktopFileSystemError.patchMismatch
        #expect(await fixture.setup(mount).state == .failed)
        #expect(!fixture.owner.observation(for: mount).verified)
        #expect(fixture.owner.observe(.removableVolumes).state == .failed)
    }

    @Test @MainActor func removedAndReappearingMountCannotResurrectOldProof() async {
        let mount = permissionMount("usb")
        let fixture = VolumePermissionFixture([mount])
        _ = await fixture.setup(mount)
        fixture.mounts = []
        #expect(fixture.owner.observe(.removableVolumes).state == .notNeeded)
        #expect(fixture.owner.observation(for: mount).state == .failed)
        fixture.mounts = [mount]
        #expect(fixture.owner.observe(.removableVolumes).state == .checking)
        #expect(fixture.checks == [mount])
    }

    @Test @MainActor func newMountDoesNotEraseOtherResourcesProofButBlocksAggregateReadiness() async {
        let first = permissionMount("a")
        let second = permissionMount("b", id: 3)
        let fixture = VolumePermissionFixture([first])
        _ = await fixture.setup(first)
        fixture.mounts = [first, second]
        #expect(fixture.owner.observe(.removableVolumes).state == .checking)
        #expect(fixture.owner.observation(for: first).verified)
        #expect(!fixture.owner.observation(for: second).verified)
    }

    @Test @MainActor func mountIdentityOrReadOnlyFlagChangeInvalidatesItsProof() async {
        let original = permissionMount("same-path")
        for replacement in [permissionMount("same-path", id: 44),
                            permissionMount("same-path", flags: UInt32(MNT_LOCAL | MNT_REMOVABLE | MNT_RDONLY))] {
            let fixture = VolumePermissionFixture([original])
            _ = await fixture.setup(original)
            fixture.mounts = [replacement]
            #expect(fixture.owner.observe(.removableVolumes).state == .checking)
            #expect(!fixture.owner.observation(for: replacement).verified)
        }
    }

    @Test @MainActor func inventoryFailureCannotMasqueradeAsAbsentMediaOrPreserveProof() async {
        let mount = permissionMount("usb")
        let fixture = VolumePermissionFixture([mount])
        _ = await fixture.setup(mount)
        fixture.inventoryFails = true
        #expect(fixture.owner.observe(.removableVolumes).state == .failed)
        #expect(await fixture.owner.setup(.removableVolumes).state == .failed)
        fixture.inventoryFails = false
        #expect(fixture.owner.observe(.removableVolumes).state == .checking)
        #expect(fixture.checks == [mount])
        fixture.mounts = [mount, mount]
        #expect(fixture.owner.observe(.removableVolumes).state == .failed)
    }

    @Test @MainActor func environmentReturnCannotResurrectProof() async {
        let mount = permissionMount("usb")
        let fixture = VolumePermissionFixture([mount])
        _ = await fixture.setup(mount)
        fixture.context = "environment-b:presentation-a"
        #expect(fixture.owner.observe(.removableVolumes).state == .checking)
        fixture.context = "environment-a:presentation-a"
        #expect(fixture.owner.observe(.removableVolumes).state == .checking)
    }

    @Test @MainActor func cancellationAndContextChangeFenceLateSuccessfulCompletion() async {
        let mount = permissionMount("usb")
        for cancel in [false, true] {
            let fixture = VolumePermissionFixture([mount])
            fixture.suspendVerification = true
            let task = Task { await fixture.setup(mount) }
            while fixture.pending.isEmpty { await Task.yield() }
            if cancel { task.cancel() } else { fixture.context = "new-environment" }
            fixture.pending[0].resume()
            #expect(await task.value.state == .checking)
            #expect(fixture.owner.observe(.removableVolumes).state == .checking)
        }
    }

    @Test @MainActor func unmountRemountAndExplicitInvalidationFencePendingProof() async {
        let mount = permissionMount("usb")
        for notification in [false, true] {
            let fixture = VolumePermissionFixture([mount])
            fixture.suspendVerification = true
            let task = Task { await fixture.setup(mount) }
            while fixture.pending.isEmpty { await Task.yield() }
            if notification { fixture.owner.invalidate() }
            else {
                fixture.mounts = []
                _ = fixture.owner.observe(.removableVolumes)
                fixture.mounts = [mount]
                _ = fixture.owner.observe(.removableVolumes)
            }
            fixture.pending[0].resume()
            #expect(await task.value.state == .checking)
            #expect(!fixture.owner.observation(for: mount).verified)
        }
    }

    @Test @MainActor func rivalSetupDoesNotSelectOrInterruptPendingCheck() async {
        let mount = permissionMount("usb")
        let fixture = VolumePermissionFixture([mount])
        fixture.suspendVerification = true
        let task = Task { await fixture.setup(mount) }
        while fixture.pending.isEmpty { await Task.yield() }
        #expect(await fixture.owner.setup(.removableVolumes).state == .checking)
        #expect(fixture.choices.count == 1 && fixture.checks == [mount])
        fixture.pending[0].resume()
        #expect(await task.value.state == .ready)
    }

    @Test @MainActor func lateOldCompletionCannotEraseSuccessorProof() async {
        let mount = permissionMount("usb")
        let fixture = VolumePermissionFixture([mount])
        fixture.suspendVerification = true
        let old = Task { await fixture.setup(mount) }
        while fixture.pending.isEmpty { await Task.yield() }
        fixture.owner.invalidate()
        let successor = Task { await fixture.setup(mount) }
        while fixture.pending.count != 2 { await Task.yield() }
        fixture.pending[1].resume()
        #expect(await successor.value.state == .ready)
        let proof = fixture.owner.observe(.removableVolumes)
        fixture.pending[0].resume()
        #expect(await old.value.state == .checking)
        #expect(fixture.owner.observe(.removableVolumes) == proof)
    }

    @Test @MainActor func preCancelledSetupDoesNotOpenChooserOrProbe() async {
        let fixture = VolumePermissionFixture([permissionMount("usb")])
        let task = Task { fixture.owner.observe(.removableVolumes); return await fixture.owner.setup(.removableVolumes) }
        task.cancel()
        #expect(await task.value.state == .checking)
        #expect(fixture.choices.isEmpty && fixture.checks.isEmpty)
    }
}
