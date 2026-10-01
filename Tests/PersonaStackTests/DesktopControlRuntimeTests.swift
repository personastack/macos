import AppKit
import Foundation
import PersonaStackCore
import ServiceManagement
import Testing
import WebKit
@testable import PersonaStack

private func waitForCredentialRead(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}

private actor DesktopControlInstallerFixture: DesktopControlDriverInstalling {
    private let errors: [any Error]
    private(set) var repairArguments: [Bool] = []

    init(errors: [any Error]) { self.errors = errors }

    func validateOrInstall(
        repair: Bool,
        commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?
    ) async throws -> CuaDriverInstallation {
        repairArguments.append(repair)
        guard let error = errors.indices.contains(repairArguments.count - 1) ? errors[repairArguments.count - 1] : nil else {
            throw CuaDriverInstallError.invalidLayout
        }
        throw error
    }
}

@MainActor
private final class FinishedDesktopControlPermissionFixture: DesktopControlPermissionPresenting {
    private(set) var isFinishing = false
    func presentForSetup() async throws { isFinishing = true }
    func completeSetup() { isFinishing = false }
    func failSetup(message: String) { isFinishing = false }
    func cancel() { isFinishing = false }
}

private struct EmptyDesktopControlCredentialStore: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { nil }
    func delete() throws {}
}

private final class PermissionPreparationCredentialStore: DesktopControlCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    let installation: DesktopControlInstallation?
    init(installation: DesktopControlInstallation?) { self.installation = installation }
    var readCount: Int { lock.withLock { reads } }
    func load() throws -> DesktopControlInstallation? { lock.withLock { reads += 1; return installation } }
    func save(_ installation: DesktopControlInstallation) throws { Issue.record("Permission preparation cannot save enrollment") }
    func delete() throws { Issue.record("Permission preparation cannot delete enrollment") }
}

private struct DeniedDesktopControlCredentialStore: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
    func delete() throws {}
}

private struct MainThreadRejectingCredentialStore: DesktopControlCredentialStoring {
    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? {
        if Thread.isMainThread { throw DesktopControlEnrollmentError.credentialStoreUnavailable }
        return nil
    }
    func delete() throws {}
}

private final class SuspendedDesktopControlCredentialStore: DesktopControlCredentialStoring, @unchecked Sendable {
    let readStarted = DispatchSemaphore(value: 0)
    let continueRead = DispatchSemaphore(value: 0)
    private let installation: DesktopControlInstallation

    init(installation: DesktopControlInstallation) { self.installation = installation }

    func save(_ installation: DesktopControlInstallation) throws {}

    func load() throws -> DesktopControlInstallation? {
        readStarted.signal()
        guard continueRead.wait(timeout: .now() + 2) == .success else {
            throw DesktopControlEnrollmentError.credentialStoreUnavailable
        }
        return installation
    }

    func delete() throws {}
}

@Test @MainActor func overlappingRepairDoesNotReplaceTheActiveLifecycle() async throws {
    let installer = DesktopControlInstallerFixture(errors: [])
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: installer, credentials: EmptyDesktopControlCredentialStore()
    )
    let first = try runtime.beginRepair()

    #expect(throws: CancellationError.self) { try runtime.beginRepair() }
    await #expect(throws: CuaDriverInstallError.self) {
        try await runtime.repair(generation: first)
    }
    _ = try runtime.beginRepair()
}

@Test @MainActor func startupRequiresAccessibleDesktopEnrollmentBeforeStartingCua() async {
    let installer = DesktopControlInstallerFixture(errors: [])
    let missing = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore())
    await #expect(throws: DesktopControlEnrollmentError.installationMissing) { try await missing.resume() }
    await #expect(throws: DesktopControlEnrollmentError.installationMissing) { try await missing.startPaused() }
    #expect(!missing.hasActiveInstallation)

    let denied = DesktopControlRuntime.makeForTesting(installer: installer, credentials: DeniedDesktopControlCredentialStore())
    await #expect(throws: DesktopControlEnrollmentError.credentialStoreUnavailable) { try await denied.resume() }
    #expect(!denied.hasActiveInstallation)
    #expect(await installer.repairArguments.isEmpty)
    #expect(DesktopControlEnrollmentError.credentialStoreUnavailable.localizedDescription.contains("Keychain"))
}

@Test @MainActor func passivePermissionSnapshotCannotInstallOrUnpauseTheRelay() async {
    let installer = DesktopControlInstallerFixture(errors: [])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore(),
                                                       readiness: "paused", paused: true)
    await #expect(throws: CuaMCPProxyError.notStarted) { try await runtime.cuaPermissionSnapshot() }
    #expect(runtime.paused)
    #expect(runtime.readiness == "paused")
    #expect(await installer.repairArguments.isEmpty)
}

@Test(arguments: ["restart", "prepare"]) @MainActor
func cuaFinishWaitsForPermissionTeardownBeforeSuccessorStartup(_ stage: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-cancel-teardown-\(stage)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, sessionLockState: .unlocked, hostPermissions: { (true, false) })
    await runtime.waitForSessionLockChangeForTesting()
    try await runtime.resumeForSetup(generation: runtime.beginResume())
    #expect(runtime.isCuaReady())
    let originalKey = try await runtime.cuaPermissionSnapshot().verificationKey
    // Pausing retires the proxy but retains the daemon. Preparation must then
    // drain that unowned daemon before creating another permission runtime.
    if stage == "prepare" { await runtime.pause() }
    let cleanup = root.appendingPathComponent("pause-daemon-cleanup")
    try Data().write(to: cleanup)
    let model = DesktopPermissionChecklistCoordinator(adapter: StartupPermissionChecklistAdapter(runtime: runtime, restart: stage == "restart"))
    model.open()
    await model.refresh()
    model.setup(.screenRecording)
    for _ in 0..<100 {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("daemon-stopping").path) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("daemon-stopping").path))
    // Cancel after daemon shutdown has started. Cleanup must remain responsive
    // and a successor must wait, even though no startup task owns this phase.
    model.finish()
    #expect(model.isFinishing)
    let successor = Task { try await runtime.resumeForSetup(generation: runtime.beginResume()) }
    for _ in 0..<10 { await Task.yield() }
    for name in ["daemon-starts", "proxy-starts"] {
        let starts = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        #expect(starts.split(separator: "\n").count == 1)
    }
    #expect(credentials.readCount == 1)
    try FileManager.default.removeItem(at: cleanup)
    do {
        try await successor.value
        #expect(runtime.isCuaReady() && runtime.readiness == "ready")
        #expect(try await runtime.cuaPermissionSnapshot().verificationKey != originalKey)
        let starts = try String(contentsOf: root.appendingPathComponent("daemon-starts"), encoding: .utf8)
        #expect(starts.split(separator: "\n").count == 2)
        #expect(credentials.readCount == 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(runtime.isCuaReady() && model.isFinishing)
        model.cancel()
        await runtime.shutdownForQuit()
    } catch { model.cancel(); await runtime.shutdownForQuit(); throw error }
}

@Test @MainActor func nativePermissionPreparationFailurePreservesPauseAndDoesNotEnroll() async {
    let installer = DesktopControlInstallerFixture(errors: [CuaDriverInstallError.invalidLayout])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore(),
                                                       readiness: "paused", paused: true, sessionLockState: .unlocked)
    await #expect(throws: CuaDriverInstallError.invalidLayout) { try await runtime.prepareCuaPermissions() }
    #expect(runtime.paused)
    #expect(runtime.readiness == "paused")
    #expect(!runtime.hasActiveInstallation)
    #expect(!runtime.gatewayConnected)
    #expect(await installer.repairArguments == [false])
}

@Test @MainActor func nativePermissionVerificationKeepsTheLockedSessionFence() async {
    let installer = DesktopControlInstallerFixture(errors: [])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore(),
                                                       readiness: "locked", sessionLockState: .locked)
    await #expect(throws: DesktopControlEnrollmentError.nativeCapabilitiesUnavailable) { try await runtime.prepareCuaPermissions() }
    await #expect(throws: CuaMCPProxyError.permissionsRequired) { try await runtime.verifyCuaCapabilitiesForPermissions() }
    #expect(await installer.repairArguments.isEmpty)
    #expect(runtime.readiness == "locked")
}

private struct EmbeddedRuntimeDriverFixture: DesktopControlDriverInstalling {
    let executable: URL
    func validateOrInstall(repair: Bool,
                          commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?) async throws -> CuaDriverInstallation {
        CuaDriverInstallation(applicationURL: executable.deletingLastPathComponent(), executableURL: executable,
                              version: CuaDriverCompatibility.version, toolNames: CuaDriverCompatibility.requiredTools)
    }
}

/// Only this fixture's socket, generated pixels, and AX text are observed.
/// It never calls Cua, TCC, or a user's desktop.
private func makeRuntimeDriverFixture(_ root: URL) throws -> URL {
    let executable = root.appendingPathComponent("driver.py")
    let script = #"""
#!/usr/bin/python3
import base64, json, os, socket, struct, sys, threading, time, zlib
args = sys.argv[1:]
path = args[args.index('--socket') + 1]
if args[0] == 'serve':
    root = os.path.dirname(os.path.realpath(__file__))
    def watch_fixture_exit():
        while True:
            if os.path.exists(os.path.join(root, 'exit-daemon')): os._exit(0)
            time.sleep(0.01)
    threading.Thread(target=watch_fixture_exit, daemon=True).start()
    ended = threading.Event()
    def read_lifetime():
        sys.stdin.buffer.read()
        ended.set()
    threading.Thread(target=read_lifetime, daemon=True).start()
    with open(os.path.join(root, 'daemon-starts'), 'a') as out: out.write(str(os.getpid())+'\n')
    if os.path.exists(os.path.join(root, 'pause-daemon-start')):
        open(os.path.join(root, 'daemon-starting'), 'w').close()
        while os.path.exists(os.path.join(root, 'pause-daemon-start')) and not ended.is_set(): time.sleep(0.01)
    def await_cleanup_release():
        if os.path.exists(os.path.join(root, 'pause-daemon-cleanup')):
            open(os.path.join(root, 'daemon-stopping'), 'w').close()
            while os.path.exists(os.path.join(root, 'pause-daemon-cleanup')): time.sleep(0.01)
    if ended.is_set():
        await_cleanup_release()
        sys.exit(0)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen(16)
    def drain_connections():
        while True:
            connection, _ = listener.accept()
            # Match the real daemon's connection lifetime. Closing before the
            # client reads LOCAL_PEERPID races the identity check under load.
            connection.settimeout(1)
            try: connection.recv(1)
            except socket.timeout: pass
            connection.close()
    threading.Thread(target=drain_connections, daemon=True).start()
    with open(args[args.index('--pid-file') + 1], 'w') as out: out.write(str(os.getpid()))
    ended.wait()
    await_cleanup_release()
    listener.close()
    sys.exit(0)
pid_path = os.path.join(os.path.dirname(path), 'daemon.pid')
for attempt in range(100):
    if os.path.exists(pid_path): break
    time.sleep(0.01)
with open(pid_path) as source: daemon = int(source.read())
host = os.getppid()
root = os.path.dirname(os.path.realpath(__file__))
def chunk(kind, data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00\x00\x00\x00'))+chunk(b'IEND',b'')
names = ['get_desktop_state','get_accessibility_tree','get_window_state','move_cursor','click','type_text','press_key','launch_app','list_apps','list_windows']
input_snapshots = 0
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    method = request['method']
    if method == 'initialize':
        with open(os.path.join(root, 'proxy-starts'), 'a') as out: out.write(str(os.getpid())+'\n')
        if os.path.exists(os.path.join(root, 'pause-proxy-start')):
            open(os.path.join(root, 'proxy-starting'), 'w').close()
            while os.path.exists(os.path.join(root, 'pause-proxy-start')): time.sleep(0.01)
        result = {'protocolVersion':'2024-11-05','capabilities':{},'serverInfo':{'name':'fixture','version':'1'}}
    elif method == 'tools/list': result = {'tools':[{'name':name} for name in names]}
    elif method == 'tools/call':
        name = request['params']['name']
        with open(os.path.join(root, 'tool-calls.jsonl'), 'a') as out: out.write(json.dumps(name)+'\n')
        if name == 'health_report':
            assert request['params']['arguments'] == {'include':['bundle_identity']}
            result = {'structuredContent':{'schema_version':'1','driver_version':'0.29.1','platform':'darwin','checks':[{'name':'bundle_identity','status':'pass','data':{'bundle_identifier':'ai.personastack.desktop','configured_bundle_identifier':'ai.personastack.desktop','identity_source':'parent_application','parent_process_id':host,'executable_path':os.path.realpath(__file__)}}]}}
        elif name == 'check_permissions':
            if os.path.exists(os.path.join(root, 'pause-permissions')):
                open(os.path.join(root, 'permissions-waiting'), 'w').close()
                while os.path.exists(os.path.join(root, 'pause-permissions')): time.sleep(0.01)
            assert request['params']['arguments'] == {'prompt':False,'probe_direct_capture':False}
            result = {'structuredContent':{'accessibility':True,'screen_recording':True,'source':{'attribution':'host','host_bundle_id':'ai.personastack.desktop','embedded':True,'disclaim_env':False,'pid':daemon,'responsible_ppid':host}}}
        elif name == 'get_desktop_state':
            assert not os.path.exists(os.path.join(root, 'screen-denied')), 'AX verification must not capture a screen'
            if os.path.exists(os.path.join(root,'exit-proxy')): os._exit(1)
            pixels = 'bad' if os.path.exists(os.path.join(root,'invalid-pixels')) else base64.b64encode(png).decode()
            result = {'content':[{'type':'image','mimeType':'image/png','data':pixels}]}
        elif name == 'get_accessibility_tree': result = {'content':[{'type':'text','text':'{"application":"fixture","children":[]}'}]}
        elif name in ['get_window_state', 'click', 'type_text']:
            arguments = request['params']['arguments']
            with open(os.path.join(root, 'input-target.json')) as source: target = json.load(source)
            assert arguments['pid'] == target['pid'] == host
            assert arguments['window_id'] == target['window_id'] == 90001
            assert arguments['session'].startswith('permissions-')
            with open(os.path.join(root, 'input-calls.jsonl'), 'a') as out: out.write(json.dumps({'name':name,'arguments':arguments})+'\n')
            base = {'session','pid','window_id'}
            if name == 'get_window_state':
                assert set(arguments) == base | {'include_screenshot','include_accessibility_tree','max_elements','max_depth','timeout_ms'}
                assert arguments['include_screenshot'] is False and arguments['include_accessibility_tree'] is True
                assert arguments['max_elements'] == 32 and arguments['max_depth'] == 8 and arguments['timeout_ms'] == 1000
                input_snapshots += 1
                sid = 's%08x' % input_snapshots
                result = {'structuredContent':{'pid':host,'window_id':90001,'snapshot_id':sid,'truncated':False,'elements_complete':False,'elements':[
                    {'element_index':3,'element_token':sid+':3','role':'AXButton','label':'Verify Desktop Control Click','enabled':True,'actions':['AXPress']},
                    {'element_index':4,'element_token':sid+':4','role':'AXTextField','label':'Desktop Control Verification Text','enabled':True}]}}
            elif name == 'click':
                assert set(arguments) == base | {'element_token','action','button','delivery_mode'}
                assert arguments['element_token'] == 's%08x:3' % input_snapshots
                assert arguments['action'] == 'press' and arguments['button'] == 'left' and arguments['delivery_mode'] == 'background'
                with open(os.path.join(root, 'input-clicked'), 'w') as out: out.write('1')
                # The canonical MCP dispatcher projects the private AX payload to ActionResult.
                result = {'structuredContent':{'route':'accessibility','effect':'unverifiable','delivery':{'mode':'background'}}}
            else:
                assert set(arguments) == base | {'element_token','text','scope','delay_ms','delivery_mode'}
                assert arguments['element_token'] == 's%08x:4' % input_snapshots
                assert arguments['scope'] == 'window' and arguments['delay_ms'] == 0 and arguments['delivery_mode'] == 'background'
                assert arguments['text'] == target['expected_text']
                with open(os.path.join(root, 'input-text'), 'w') as out: out.write(arguments['text'])
                result = {'structuredContent':{'route':'accessibility','effect':'confirmed','delivery':{'mode':'background','delivered_count':len(arguments['text'])},'evidence':[{'kind':'value_readback'}]}}
        else: raise RuntimeError('unplanned tool: '+name)
    else: raise RuntimeError('unplanned method: '+method)
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}), flush=True)
"""#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

@MainActor
private final class RuntimeInputTarget: DesktopInputPermissionTarget {
    let pid = Darwin.getpid()
    let windowID = 90001
    let expectedText = "PersonaStack fixture input"
    private let root: URL
    private(set) var presented = false
    private(set) var invalidated = false
    var onClickObserved: (() throws -> Void)?
    private var clickObserved = false
    init(root: URL) { self.root = root }
    var clickCount: Int { FileManager.default.fileExists(atPath: root.appendingPathComponent("input-clicked").path) ? 1 : 0 }
    var text: String { (try? String(contentsOf: root.appendingPathComponent("input-text"), encoding: .utf8)) ?? "" }
    func present() throws {
        presented = true
        let data = try JSONSerialization.data(withJSONObject: ["pid": pid, "window_id": windowID, "expected_text": expectedText])
        try data.write(to: root.appendingPathComponent("input-target.json"))
    }
    func requireCurrent() throws {
        guard presented, !invalidated else { throw CancellationError() }
        if clickCount > 0, !clickObserved {
            clickObserved = true
            try onClickObserved?()
        }
    }
    func invalidate() { invalidated = true }
    var calls: [String] {
        let data = (try? String(contentsOf: root.appendingPathComponent("input-calls.jsonl"), encoding: .utf8)) ?? ""
        return data.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["name"] as? String
        }
    }
}

@Test @MainActor func cuaPermissionGrantRetryUsesDarwinHealthAndPreservesOwnership() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-grant-retry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    var granted = false
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, readiness: "paused", paused: true, sessionLockState: .unlocked,
        hostPermissions: { (granted, granted) })
    do {
        // An identifiable owned service is valid even before OS grants exist.
        try await runtime.prepareCuaPermissions()
        let denied = try await runtime.cuaPermissionSnapshot()
        #expect(denied.hostAttributionValid && !denied.accessibility && !denied.screenRecording)
        #expect(!runtime.isCuaReady())

        granted = true
        try await runtime.restartCuaAfterPermissionChange()
        let allowed = try await runtime.cuaPermissionSnapshot()
        #expect(allowed.hostAttributionValid && allowed.accessibility && allowed.screenRecording)
        #expect(allowed.verificationKey != denied.verificationKey)
        #expect(!runtime.isCuaReady())
        try await runtime.verifyCuaCapabilitiesForPermissions()
        #expect(runtime.isCuaReady())

        // Revocation removes functional proof without misclassifying the host.
        granted = false
        let revoked = try await runtime.cuaPermissionSnapshot()
        #expect(revoked.hostAttributionValid && !revoked.accessibility && !revoked.screenRecording)
        #expect(!runtime.isCuaReady())
        #expect(credentials.readCount == 0)
        #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
        #expect(runtime.paused && runtime.readiness == "paused")
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

private func runtimeFixtureCalls(_ root: URL) throws -> [String] {
    let data = try String(contentsOf: root.appendingPathComponent("tool-calls.jsonl"), encoding: .utf8)
    return try data.split(separator: "\n").map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func permissionOnlyUnlockWaitsForExplicitSetupWithoutCredentialsOrCapture(granted: Bool, paused: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-permission-unlock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    // A saved installation must not turn permission preparation into a relay.
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"saved-preflight","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8))
    let credentials = PermissionPreparationCredentialStore(installation: installation)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, paused: paused, sessionLockState: .unlocked, hostPermissions: { (granted, granted) })
    do {
        await runtime.waitForSessionLockChangeForTesting()
        try await runtime.prepareCuaPermissions()
        let preparedCalls = try runtimeFixtureCalls(root)
        #expect(!preparedCalls.contains("get_desktop_state") && !preparedCalls.contains("get_accessibility_tree"))
        runtime.receiveSessionLockForTesting(.locked)
        await runtime.waitForSessionLockChangeForTesting()
        #expect(runtime.readiness == "locked" && !runtime.isCuaReady())
        runtime.receiveSessionLockForTesting(.unlocked)
        await runtime.waitForSessionLockChangeForTesting()
        #expect(try runtimeFixtureCalls(root) == preparedCalls)
        #expect(credentials.readCount == 0)
        #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
        #expect(runtime.paused == paused && runtime.readiness == (paused ? "paused" : "permission_required"))
        #expect(!runtime.isCuaReady())
        // Only another explicit action can replace the interrupted proxy and verify.
        try await runtime.prepareCuaPermissions()
        if granted {
            try await runtime.verifyCuaCapabilitiesForPermissions()
            #expect(runtime.isCuaReady())
        } else {
            await #expect(throws: CuaMCPProxyError.permissionsRequired) { try await runtime.verifyCuaCapabilitiesForPermissions() }
            #expect(!runtime.isCuaReady())
        }
        #expect(credentials.readCount == 0 && runtime.paused == paused)
        #expect(!runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

@Test(arguments: [false, true]) @MainActor
func fullSetupAfterPermissionPreparationRestoresAutomaticUnlockRecovery(grantedAfterUnlock: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-full-unlock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    var granted = true
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, sessionLockState: .unlocked, hostPermissions: { (granted, granted) })
    do {
        await runtime.waitForSessionLockChangeForTesting()
        try await runtime.prepareCuaPermissions()
        #expect(credentials.readCount == 0 && !runtime.isCuaReady())
        // The existing post-Finish startup path explicitly authorizes full recovery.
        try await runtime.resumeForSetup(generation: runtime.beginResume())
        #expect(runtime.isCuaReady() && credentials.readCount == 1)
        runtime.receiveSessionLockForTesting(.locked)
        await runtime.waitForSessionLockChangeForTesting()
        let beforeUnlock = try runtimeFixtureCalls(root)
        granted = grantedAfterUnlock
        runtime.receiveSessionLockForTesting(.unlocked)
        await runtime.waitForSessionLockChangeForTesting()
        let recoveryCalls = Array(try runtimeFixtureCalls(root).dropFirst(beforeUnlock.count))
        #expect(recoveryCalls.contains("check_permissions"))
        #expect(!recoveryCalls.contains("get_desktop_state"))
        #expect(recoveryCalls.contains("get_accessibility_tree") == grantedAfterUnlock)
        #expect(runtime.isCuaReady() == grantedAfterUnlock)
        #expect(runtime.readiness == (grantedAfterUnlock ? "ready" : "permission_required"))
        #expect(credentials.readCount == 2 && !runtime.paused)
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

@Test(arguments: [false, true]) @MainActor
func enrolledRuntimeKeepsUnlockRecoveryDuringPermissionRepair(grantedAfterUnlock: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-enrolled-unlock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    // Omit environment binding deliberately. The gateway rejects this fixture
    // before creating a URLSession task, while the real reconnect owner exists.
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"saved-recovery","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8))
    #expect(throws: DesktopControlEnrollmentError.invalidRequest) { try installation.requireBoundGateway() }
    let credentials = PermissionPreparationCredentialStore(installation: installation)
    var granted = true
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, sessionLockState: .unlocked, hostPermissions: { (granted, granted) })
    do {
        await runtime.waitForSessionLockChangeForTesting()
        try await runtime.resume()
        #expect(runtime.isCuaReady() && runtime.hasActiveInstallation && runtime.hasPendingRelayReconnectForTesting)
        try await runtime.prepareCuaPermissions()
        try await runtime.restartCuaAfterPermissionChange()
        let beforeUnlock = try runtimeFixtureCalls(root)
        runtime.receiveSessionLockForTesting(.locked)
        await runtime.waitForSessionLockChangeForTesting()
        granted = grantedAfterUnlock
        runtime.receiveSessionLockForTesting(.unlocked)
        await runtime.waitForSessionLockChangeForTesting()
        let recoveryCalls = Array(try runtimeFixtureCalls(root).dropFirst(beforeUnlock.count))
        #expect(recoveryCalls.contains("check_permissions"))
        #expect(!recoveryCalls.contains("get_desktop_state"))
        #expect(runtime.isCuaReady() == grantedAfterUnlock)
        #expect(runtime.readiness == (grantedAfterUnlock ? "ready" : "permission_required"))
        #expect(runtime.hasActiveInstallation && runtime.hasPendingRelayReconnectForTesting && !runtime.gatewayConnected)
        #expect(credentials.readCount == 1)
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

@Test @MainActor func permissionRetryRetiresFailedFullStartupRecovery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-failed-full-unlock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, sessionLockState: .unlocked, hostPermissions: { (false, false) })
    do {
        await runtime.waitForSessionLockChangeForTesting()
        await #expect(throws: CuaMCPProxyError.permissionsRequired) {
            try await runtime.resumeForSetup(generation: runtime.beginResume())
        }
        #expect(credentials.readCount == 1)
        try await runtime.prepareCuaPermissions()
        let beforeUnlock = try runtimeFixtureCalls(root)
        runtime.receiveSessionLockForTesting(.locked)
        await runtime.waitForSessionLockChangeForTesting()
        runtime.receiveSessionLockForTesting(.unlocked)
        await runtime.waitForSessionLockChangeForTesting()
        #expect(try runtimeFixtureCalls(root) == beforeUnlock)
        #expect(credentials.readCount == 1 && !runtime.hasPendingRelayReconnectForTesting)
        #expect(runtime.readiness == "permission_required" && !runtime.isCuaReady())
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

@Test(arguments: [false, true]) @MainActor func permissionInputUsesOnlyTheOwnedWindowAndNeverStartsEnrollment(screenGranted: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-input-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    if !screenGranted { try Data().write(to: root.appendingPathComponent("screen-denied")) }
    let executable = try makeRuntimeDriverFixture(root)
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, readiness: "paused", paused: true, sessionLockState: .unlocked, hostPermissions: { (true, screenGranted) })
    do {
        try await runtime.prepareCuaPermissions()
        if screenGranted { try await runtime.verifyCuaCapabilitiesForPermissions() }
        let target = RuntimeInputTarget(root: root)
        try await runtime.verifyCuaInputForPermissions(target: target)
        #expect(runtime.isCuaReady() == screenGranted)
        #expect(target.calls == ["get_window_state", "click", "get_window_state", "type_text"])
        #expect(target.clickCount == 1 && target.text == target.expectedText && target.invalidated)
        #expect(credentials.readCount == 0)
        #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
        #expect(runtime.paused && runtime.readiness == "paused")
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

@Test(arguments: ["lifecycle", "lock"]) @MainActor func permissionInputRejectsLateLifecycleChangeWithoutTyping(change: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-input-stale-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: PermissionPreparationCredentialStore(installation: nil), sessionLockState: .unlocked, hostPermissions: { (true, true) })
    do {
        try await runtime.prepareCuaPermissions()
        try await runtime.verifyCuaCapabilitiesForPermissions()
        let target = RuntimeInputTarget(root: root)
        target.onClickObserved = {
            if change == "lock" { runtime.receiveSessionLockForTesting(.locked) }
            else { _ = try runtime.beginResume() }
        }
        await #expect(throws: CancellationError.self) { try await runtime.verifyCuaInputForPermissions(target: target) }
        #expect(target.calls == ["get_window_state", "click"])
        #expect(target.text.isEmpty && target.invalidated)
        if change == "lock" { await runtime.waitForLockCleanupForTesting() }
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

@Test @MainActor func permissionInputPreservesAnExistingRemoteLeaseWithoutOpeningItsWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-input-busy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, executor: executor, sessionLockState: .unlocked, hostPermissions: { (true, true) })
    do {
        try await runtime.prepareCuaPermissions()
        try await runtime.verifyCuaCapabilitiesForPermissions()
        let owner = DesktopControlTarget(installationID: "install", workspaceID: "workspace", configID: "config",
                                        personaID: "persona", runID: "run", generation: 1, configVersion: 1)
        let acquire = DesktopControlFrame(type: "command", requestID: "acquire", target: owner, operation: "desktop_control_acquire", arguments: .object([:]))
        let first = await executor.handle(acquire, proxy: nil)
        #expect(first.type == "result")
        let target = RuntimeInputTarget(root: root)
        await #expect(throws: DesktopInputPermissionVerificationError.busy) { try await runtime.verifyCuaInputForPermissions(target: target) }
        #expect(!target.presented && target.invalidated && target.calls.isEmpty)
        let renewed = await executor.handle(acquire, proxy: nil)
        #expect(renewed.type == "result" && renewed.result == first.result)
        #expect(credentials.readCount == 0)
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

@Test @MainActor func permissionInputWithoutUsableOwnedCuaNeverOpensAWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-input-denied-\(UUID().uuidString)")
    let target = RuntimeInputTarget(root: root)
    let runtime = DesktopControlRuntime.makeForTesting(installer: DesktopControlInstallerFixture(errors: []),
        credentials: PermissionPreparationCredentialStore(installation: nil), sessionLockState: .locked)
    await #expect(throws: CuaMCPProxyError.permissionsRequired) { try await runtime.verifyCuaInputForPermissions(target: target) }
    #expect(!target.presented && target.invalidated && target.calls.isEmpty)
    await runtime.shutdownForQuit()
}

@Test @MainActor func permissionPreparationCannotAdvertiseGuiReadyWithoutCurrentGrantsAndPixels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-runtime-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    var grants = false
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"saved-preflight","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8))
    let credentials = PermissionPreparationCredentialStore(installation: installation)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: EmbeddedRuntimeDriverFixture(executable: executable), credentials: credentials,
        readiness: "paused", paused: true, sessionLockState: .unlocked, hostPermissions: { (grants, grants) }
    )
    do {
        try await runtime.prepareCuaPermissions()
        let initial = try await runtime.cuaPermissionSnapshot()
        #expect(initial.hostAttributionValid && !initial.accessibility && !initial.screenRecording)
        #expect(!runtime.isCuaReady())
        #expect(runtime.paused && runtime.readiness == "paused")
        #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected)
        await #expect(throws: CuaMCPProxyError.permissionsRequired) { try await runtime.verifyCuaCapabilitiesForPermissions() }
        try await runtime.prepareCuaPermissions()
        #expect(try await runtime.cuaPermissionSnapshot().verificationKey == initial.verificationKey)
        grants = true
        #expect(!runtime.isCuaReady())
        try await runtime.verifyCuaCapabilitiesForPermissions()
        #expect(runtime.isCuaReady())
        #expect(runtime.paused && runtime.readiness == "paused")
        grants = false
        #expect(!runtime.isCuaReady())
        grants = true
        #expect(!runtime.isCuaReady())
        let exitProxy = root.appendingPathComponent("exit-proxy")
        try Data().write(to: exitProxy)
        await #expect(throws: CuaMCPProxyError.processExited) { try await runtime.verifyCuaCapabilitiesForPermissions() }
        #expect(!runtime.isCuaReady())
        try FileManager.default.removeItem(at: exitProxy)
        try await runtime.prepareCuaPermissions()
        #expect(try await runtime.cuaPermissionSnapshot().verificationKey == initial.verificationKey)
        #expect(runtime.paused && runtime.readiness == "paused")
        try await runtime.verifyCuaCapabilitiesForPermissions()
        #expect(runtime.isCuaReady())
        let exitDaemon = root.appendingPathComponent("exit-daemon")
        try Data().write(to: exitDaemon)
        for _ in 0..<100 {
            if (try? await runtime.cuaPermissionSnapshot()) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!runtime.isCuaReady())
        try FileManager.default.removeItem(at: exitDaemon)
        try await runtime.prepareCuaPermissions()
        let replacement = try await runtime.cuaPermissionSnapshot()
        #expect(replacement.verificationKey != initial.verificationKey)
        #expect(runtime.paused && runtime.readiness == "paused")
        #expect(!runtime.isCuaReady())
        try await runtime.verifyCuaCapabilitiesForPermissions()
        #expect(runtime.isCuaReady())
        try Data().write(to: root.appendingPathComponent("invalid-pixels"))
        await #expect(throws: CuaMCPProxyError.functionalProbeFailed) { try await runtime.verifyCuaCapabilitiesForPermissions() }
        #expect(runtime.isCuaReady())
        try await runtime.restartCuaAfterPermissionChange()
        #expect(try await runtime.cuaPermissionSnapshot().verificationKey != initial.verificationKey)
        #expect(runtime.paused && runtime.readiness == "paused")
        #expect(!runtime.isCuaReady())
        #expect(credentials.readCount == 0)
        #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
        await runtime.shutdownForQuit()
    } catch {
        await runtime.shutdownForQuit()
        throw error
    }
}

@Test @MainActor func permissionPreparationFailureCannotReadSavedEnrollmentOrReconnect() async throws {
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: Data(#"{"installation_id":"saved-preflight","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8))
    let credentials = PermissionPreparationCredentialStore(installation: installation)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: [CuaDriverInstallError.invalidLayout]),
        credentials: credentials, readiness: "paused", paused: true, sessionLockState: .unlocked
    )
    await #expect(throws: CuaDriverInstallError.invalidLayout) { try await runtime.prepareCuaPermissions() }
    #expect(credentials.readCount == 0)
    #expect(!runtime.hasActiveInstallation && !runtime.gatewayConnected && !runtime.hasPendingRelayReconnectForTesting)
    #expect(runtime.paused && runtime.readiness == "paused")
}

@Test @MainActor func heartbeatStopsReportingReadyAfterEmbeddedCuaProxyExits() async {
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(),
        proxy: CuaMCPProxy(executableURL: URL(fileURLWithPath: "/nonexistent/cua-driver")),
        readiness: "ready"
    )

    #expect(await runtime.heartbeatReadinessForTesting() == "cua_unavailable")
    #expect(runtime.readiness == "cua_unavailable")
}

@Test @MainActor func startupReadsKeychainAwayFromTheMainActor() async {
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: MainThreadRejectingCredentialStore()
    )
    await #expect(throws: DesktopControlEnrollmentError.installationMissing) { try await runtime.resume() }
    await #expect(throws: DesktopControlEnrollmentError.installationMissing) { try await runtime.startPaused() }
}

@Test @MainActor func setupStateReadsKeychainAwayFromTheMainActor() async throws {
    let appURL = URL(string: "https://my.personastack.ai")!
    let credentials = MainThreadRejectingCredentialStore()
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []), credentials: credentials
    )
    let page = DesktopControlSetupManager.Page(appURL: appURL)
    let runtimeState = try await DesktopControlSetupManager(runtime: runtime).apply(.state(scope: ""), page: page)
    #expect(runtimeState["installation_id"] is NSNull)

    let injectedState = try await DesktopControlSetupManager(
        runtime: DesktopControlSetupRuntimeFixture(), credentials: credentials
    ).apply(.state(scope: ""), page: page)
    #expect(injectedState["installation_id"] is NSNull)
}

@Test @MainActor func unregisterFencesQueuedSetupCallbacks() async throws {
    let appURL = URL(string: "https://my.personastack.ai")!
    let runtime = DesktopControlSetupRuntimeFixture()
    let manager = DesktopControlSetupManager(runtime: runtime)
    let view = WKWebView()
    manager.register(view, appURL: appURL)
    let page = try #require(manager.registeredPage(for: view))
    var replyError: String?

    manager.dispatch(["version": "1", "action": "sync", "scope": ""], page: page) { _, error in
        replyError = error
    }
    manager.unregister(view)
    await Task.yield()

    #expect(replyError != nil)
    #expect(runtime.finishSetupCalls == 0)
    #expect(manager.registeredPage(for: view) == nil)
}

@Test @MainActor func macOSLockFencesCommandsBeforeAsynchronousHeartbeat() async {
    let power = DesktopControlPowerAssertion.testFixture()
    let executor = DesktopControlCommandExecutor(powerAssertion: power)
    let owner = DesktopControlTarget(installationID: "install", workspaceID: "workspace", configID: "config",
                                     personaID: "persona", runID: "run", generation: 1, configVersion: 1)
    let acquire = DesktopControlFrame(type: "command", requestID: "lock-power-acquire", target: owner,
                                      operation: "desktop_control_acquire", arguments: .object([:]))
    #expect(await executor.handle(acquire, proxy: nil).type == "result")
    #expect(power.isHeld)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(), executor: executor,
        sessionLockState: .locked
    )
    #expect(runtime.lockCleanupStartedForTesting)
    #expect(runtime.readiness == "locked")
    await runtime.waitForLockCleanupForTesting()
    #expect(!power.isHeld)
    _ = await executor.close()
}

private struct SavedDesktopControlCredentialStore: DesktopControlCredentialStoring {
    let installation: DesktopControlInstallation

    func save(_ installation: DesktopControlInstallation) throws {}
    func load() throws -> DesktopControlInstallation? { installation }
    func delete() throws {}
}

@Test @MainActor func quitFencesTheRelayAndLeavesEnrollmentForNextLaunch() async throws {
    let payload = Data(#"{"installation_id":"installation-quit","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let power = DesktopControlPowerAssertion.testFixture()
    let executor = DesktopControlCommandExecutor(powerAssertion: power)
    let owner = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace", configID: "config",
                                     personaID: "persona", runID: "run", generation: 1, configVersion: 1)
    let acquire = DesktopControlFrame(type: "command", requestID: "quit-power-acquire", target: owner,
                                      operation: "desktop_control_acquire", arguments: .object([:]))
    #expect(await executor.handle(acquire, proxy: nil).type == "result")
    #expect(power.isHeld)
    var cuaStops = 0
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        executor: executor, installation: installation, connected: true, readiness: "ready",
        ownedCuaService: CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua")),
        stopCuaService: { _ in cuaStops += 1; return true })
    let generation = try runtime.beginResume()

    await runtime.shutdownForQuit()

    #expect(!power.isHeld)
    #expect(!runtime.isCurrentLifecycle(generation))
    #expect(runtime.paused)
    #expect(runtime.readiness == "paused")
    #expect(!runtime.gatewayConnected)
    #expect(!runtime.hasActiveInstallation)
    #expect(cuaStops == 1)
}

@Test @MainActor func machineDisconnectStopsOnlyCuaStartedByThisApp() async throws {
    for ownsCua in [false, true] {
        var cuaStops = 0
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []),
            credentials: EmptyDesktopControlCredentialStore(),
            ownedCuaService: ownsCua ? CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua")) : nil,
            stopCuaService: { _ in cuaStops += 1; return true }
        )

        try await runtime.disconnect()

        #expect(cuaStops == (ownsCua ? 1 : 0))
        #expect(!runtime.gatewayConnected)
    }
}

@Test @MainActor func machineDisconnectReportsOwnedCuaStopFailure() async throws {
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(),
        ownedCuaService: CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua")),
        stopCuaService: { _ in false }
    )

    do {
        try await runtime.disconnect()
        Issue.record("expected local Cua cleanup failure")
    } catch {
        #expect(error.localizedDescription.contains("PersonaStack could not stop its desktop control service"))
    }
    #expect(!runtime.gatewayConnected)
}

@Test @MainActor func environmentSwitchStopsLocalControlButKeepsTheOldEnrollment() async throws {
    let payload = Data(#"{"installation_id":"installation-switch","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    var cuaStops = 0
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        installation: installation,
        connected: true,
        readiness: "ready",
        ownedCuaService: CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua")),
        stopCuaService: { _ in cuaStops += 1; return true }
    )

    try await runtime.prepareForEnvironmentSwitch()

    #expect(runtime.paused)
    #expect(!runtime.gatewayConnected)
    #expect(!runtime.hasActiveInstallation)
    #expect(runtime.readiness == "unknown")
    #expect(cuaStops == 1)
    #expect(try await runtime.savedInstallationForTesting()?.installationID == installation.installationID)
}

@Test @MainActor func setupCredentialReadCannotRestoreOldInstallationAfterEnvironmentSwitch() async throws {
    let payload = Data(#"{"installation_id":"installation-late-read","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(DesktopEnvironmentConfiguration.production.appPageURL,
                                     configuration: .production)
    let credentials = SuspendedDesktopControlCredentialStore(installation: installation)
    let changed = try DesktopEnvironmentConfiguration(
        appURL: "https://my.personastack.ai",
        gatewayURL: "https://gateway-alt.example",
        mcpURL: "https://mcp-alt.example"
    )
    var selectedConfiguration = DesktopEnvironmentConfiguration.production
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: credentials,
        configurationProvider: { selectedConfiguration }
    )
    let finishingSetup = Task { @MainActor in await runtime.finishSetupIfIdle() }
    let readStarted = await Task.detached { waitForCredentialRead(credentials.readStarted) }.value
    #expect(readStarted)

    try await runtime.prepareForEnvironmentSwitch()
    selectedConfiguration = changed
    runtime.completeEnvironmentSwitch()
    credentials.continueRead.signal()
    await finishingSetup.value

    #expect(!runtime.hasActiveInstallation)
}

@Test @MainActor func savedInstallationValidatesProfileBeforeCachingCredential() async throws {
    let payload = Data(#"{"installation_id":"installation-wrong-gateway","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://unrelated.example/v1/desktop-control/ws","environment_origin":"https://my.personastack.ai"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation)
    )

    await #expect(throws: DesktopControlEnrollmentError.invalidRequest) {
        try await runtime.savedInstallation(for: URL(string: "https://my.personastack.ai/user/personas")!)
    }

    #expect(!runtime.hasActiveInstallation)
}

@Test @MainActor func failedEnvironmentSwitchKeepsRemoteControlFenced() async throws {
    let payload = Data(#"{"installation_id":"installation-switch-failure","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        installation: installation,
        connected: true,
        readiness: "ready",
        ownedCuaService: CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua")),
        stopCuaService: { _ in false }
    )

    await #expect(throws: DesktopControlEnvironmentSwitchError.cleanupFailed) {
        try await runtime.prepareForEnvironmentSwitch()
    }

    #expect(runtime.paused)
    #expect(!runtime.gatewayConnected)
    #expect(runtime.readiness == "cua_unavailable")
    #expect(!runtime.hasActiveInstallation)
    runtime.abortEnvironmentSwitch()
    #expect(runtime.hasPendingEnvironmentSwitch)
    #expect(!runtime.isReady())
    #expect(throws: CancellationError.self) { try runtime.beginResume() }
    let repairGeneration = try runtime.beginRepair()
    #expect(runtime.isCurrentLifecycle(repairGeneration))
}

@Test @MainActor func failedEnvironmentSwitchCanStillBeDisconnected() async throws {
    let payload = Data(#"{"installation_id":"installation-switch-disconnect","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        installation: installation,
        connected: true,
        readiness: "ready",
        ownedCuaService: CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua")),
        stopCuaService: { _ in false }
    )

    await #expect(throws: DesktopControlEnvironmentSwitchError.cleanupFailed) {
        try await runtime.prepareForEnvironmentSwitch()
    }
    runtime.abortEnvironmentSwitch()

    _ = try runtime.beginDisconnect()
}

@Test @MainActor func quitWaitsForCleanupAndRepliesOnlyOnce() async {
    var cleanupCalls = 0
    var replies = 0
    let delegate = PersonaStackTerminationDelegate(
        shutdown: { cleanupCalls += 1 },
        reply: { _ in replies += 1 },
        timeout: .seconds(1))
    let app = NSApplication.shared

    #expect(delegate.applicationShouldTerminate(app) == .terminateLater)
    #expect(delegate.applicationShouldTerminate(app) == .terminateLater)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(cleanupCalls == 1)
    #expect(replies == 1)
}

@Test @MainActor func quitDeadlineRepliesWhenCleanupIsSlow() async {
    var replies = 0
    var cleanupContinuation: CheckedContinuation<Void, Never>?
    let delegate = PersonaStackTerminationDelegate(
        shutdown: { await withCheckedContinuation { cleanupContinuation = $0 } },
        reply: { _ in replies += 1 },
        timeout: .milliseconds(10))

    #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
    for _ in 0..<100 where cleanupContinuation == nil {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(cleanupContinuation != nil)
    for _ in 0..<100 where replies == 0 {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(replies == 1)
    cleanupContinuation?.resume()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(replies == 1)
}

private actor DesktopControlRelayStateFixture: DesktopControlRelayStateReading {
    let active: Bool

    init(active: Bool) { self.active = active }

    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool {
        active
    }
}

@MainActor
private final class DesktopControlSetupRuntimeFixture: DesktopControlSetupRuntime {
    private(set) var attempts = 0
    private(set) var repairAttempts = 0
    private(set) var gatewayConnected = false
    private(set) var paused = false
    var nativeExecutorReady = true
    private(set) var ready = false
    private(set) var nativeProbeCount = 0
    private(set) var connectedInstallationID = ""
    private(set) var finishSetupCalls = 0
    private(set) var disconnectCalls = 0
    var permissionGranted = false
    var disconnectError: (any Error)?
    private var generation = UUID()
    var readiness: String { ready ? "ready" : "permission_required" }

    func isCuaReady() -> Bool { ready }

    func probeNativeCapabilities(generation: UUID) async throws {
        guard isCurrentLifecycle(generation) else { throw CancellationError() }
        nativeProbeCount += 1
    }

    func beginResume() throws -> UUID {
        generation = UUID()
        return generation
    }

    func resume(generation: UUID) async throws {
        guard isCurrentLifecycle(generation) else { throw CancellationError() }
        attempts += 1
        guard permissionGranted else { throw CuaMCPProxyError.permissionsRequired }
        ready = true
        paused = false
    }

    func resumeForSetup(generation: UUID) async throws {
        try await resume(generation: generation)
    }

    func finishSetupIfIdle() async { finishSetupCalls += 1 }
    func disconnect() async throws {
        disconnectCalls += 1
        if let disconnectError { throw disconnectError }
    }

    func repair(resumeRelay: Bool, expectedGeneration: UUID?) async throws -> UUID {
        repairAttempts += 1
        throw CuaMCPProxyError.functionalProbeFailed
    }

    func isCurrentLifecycle(_ generation: UUID) -> Bool { self.generation == generation }

    func connect(installation: DesktopControlInstallation, expectedGeneration: UUID?) async {
        connectedInstallationID = installation.installationID
        gatewayConnected = true
    }

    func savedInstallation(for appURL: URL) async throws -> DesktopControlInstallation? { nil }
}

@Test @MainActor func setupDoesNotAttachWhenLocalDisconnectFails() async throws {
    let installationPayload = Data(#"{"installation_id":"installation-disconnect-failure","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let appURL = URL(string: "https://my.personastack.ai")!
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: installationPayload)
    try installation.bindEnvironment(appURL)
    let runtime = DesktopControlSetupRuntimeFixture()
    runtime.disconnectError = DesktopControlEnrollmentError.revocationFailed
    let enrollment = DesktopControlSetupEnrollmentFixture()
    let manager = DesktopControlSetupManager(
        runtime: runtime,
        enrollment: enrollment,
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        configurationProvider: { .production },
        permissionPresenter: FinishedDesktopControlPermissionFixture()
    )
    let page = DesktopControlSetupManager.Page(appURL: appURL)
    page.setupScope.synchronize("workspace-setup-session")

    _ = try await manager.apply(.permissions(scope: "workspace-setup-session", phase: .open, message: nil), page: page)

    do {
        _ = try await manager.apply(
            .prepare(scope: "workspace-setup-session", enrollmentTicket: String(repeating: "a", count: 43)),
            page: page
        )
        Issue.record("setup must preserve the existing link when local disconnect fails")
    } catch let error as DesktopControlEnrollmentError {
        #expect(error == .revocationFailed)
    } catch {
        Issue.record("unexpected setup error: \(error)")
    }

    #expect(runtime.disconnectCalls == 1)
    #expect(await enrollment.attachedTicketInstallationIDs.isEmpty)
    #expect(runtime.attempts == 0)
}

private actor DesktopControlSetupEnrollmentFixture: DesktopControlSetupEnrollment {
    private(set) var readyInstallationIDs: [String] = []
    private(set) var attachedTicketInstallationIDs: [String] = []

    func enroll(
        ticket: String,
        appURL: URL,
        commitCredential: (@MainActor @Sendable (DesktopControlInstallation) throws -> Void)?
    ) async throws -> DesktopControlInstallation {
        throw DesktopControlEnrollmentError.rejected
    }

    func reportReady(installation: DesktopControlInstallation, appURL: URL) async throws {
        readyInstallationIDs.append(installation.installationID)
    }

    func attach(ticket: String, installation: DesktopControlInstallation, appURL: URL) async throws {
        attachedTicketInstallationIDs.append(installation.installationID)
    }

    func configurationState(installation: DesktopControlInstallation, appURL: URL) async throws -> DesktopControlConfigurationState {
        DesktopControlConfigurationState(hasActiveConfig: false, hasConfig: false)
    }

    func hasActiveConfig(installation: DesktopControlInstallation, appURL: URL) async throws -> Bool { true }
}

@Test @MainActor func repairDoesNotForceReinstallWhenCuaNeedsPermission() async throws {
    let installer = DesktopControlInstallerFixture(errors: [CuaMCPProxyError.permissionsRequired])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore())

    await #expect(throws: CuaMCPProxyError.permissionsRequired) {
        try await runtime.repair()
    }

    #expect(await installer.repairArguments == [false])
    #expect(runtime.readiness == "permission_required")
}

@Test @MainActor func foregroundSetupConfirmationAllowsOnlyUnknownSession() {
    let lock = DesktopControlSessionLock(observeSystem: false)
    #expect(!lock.allowsControl)
    lock.confirmForegroundSetup()
    #expect(lock.allowsControl)
    lock.receive(.locked)
    lock.confirmForegroundSetup()
    #expect(!lock.allowsControl)
    lock.receive(.unlocked)
    #expect(lock.allowsControl)
}

@Test @MainActor func restartConfirmationRequiresForegroundApprovalAndNeverOverridesLock() throws {
    let denied = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(),
        confirmForegroundSetup: { false }
    )
    #expect(denied.requiresForegroundSessionConfirmation)
    #expect(throws: CancellationError.self) { try denied.confirmForegroundSession() }
    #expect(denied.requiresForegroundSessionConfirmation)

    let approved = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(),
        confirmForegroundSetup: { true }
    )
    try approved.confirmForegroundSession()
    #expect(!approved.requiresForegroundSessionConfirmation)
    #expect(approved.sessionRecoveryMessage == nil)

    let locked = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: EmptyDesktopControlCredentialStore(),
        sessionLockState: .locked,
        confirmForegroundSetup: { true }
    )
    #expect(!locked.requiresForegroundSessionConfirmation)
    #expect(throws: DesktopControlEnrollmentError.self) { try locked.confirmForegroundSession() }
    #expect(locked.sessionRecoveryMessage == "Unlock this Mac to enable remote control.")
}

@Test @MainActor func repairAllowsOnlyOneForcedInstallAfterRetryableFailure() async throws {
    let installer = DesktopControlInstallerFixture(errors: [CuaDriverInstallError.invalidLayout, CuaDriverInstallError.invalidLayout])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore())

    await #expect(throws: CuaDriverInstallError.invalidLayout) {
        try await runtime.repair()
    }

    #expect(await installer.repairArguments == [false, true])
    #expect(runtime.readiness == "cua_unavailable")
}

@Test @MainActor func setupPrepareAcceptsRepeatedPermissionRetryAttemptsWithoutForcedInstall() async throws {
    let installer = DesktopControlInstallerFixture(errors: [
        CuaMCPProxyError.permissionsRequired,
        CuaMCPProxyError.permissionsRequired,
    ])
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: EmptyDesktopControlCredentialStore())
    let manager = DesktopControlSetupManager(runtime: runtime, credentials: EmptyDesktopControlCredentialStore(),
                                            permissionPresenter: FinishedDesktopControlPermissionFixture())
    let page = DesktopControlSetupManager.Page(appURL: URL(string: "https://personastack.ai")!)
    page.setupScope.synchronize("workspace-setup-session")
    let command = DesktopControlSetupCommand.prepare(
        scope: "workspace-setup-session",
        enrollmentTicket: String(repeating: "a", count: 43)
    )

    _ = try await manager.apply(.permissions(scope: "workspace-setup-session", phase: .open, message: nil), page: page)

    for _ in 0..<2 {
        do {
            _ = try await manager.apply(command, page: page)
            Issue.record("permission denial should leave setup available for another attempt")
        } catch let error as CuaMCPProxyError {
            #expect(error == .permissionsRequired)
        } catch {
            Issue.record("unexpected setup error: \(error)")
        }
    }

    #expect(await installer.repairArguments == [false, false])
    #expect(runtime.readiness == "permission_required")
}

@Test @MainActor func setupCancellationBeforeUnknownLockConfirmationDoesNotStartCua() async throws {
    let installer = DesktopControlInstallerFixture(errors: [])
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: installer,
        credentials: EmptyDesktopControlCredentialStore(),
        confirmForegroundSetup: { false }
    )
    let generation = try runtime.beginResume()

    await #expect(throws: CancellationError.self) {
        try await runtime.resumeForSetup(generation: generation)
    }
    #expect(await installer.repairArguments.isEmpty)
}

@Test @MainActor func setupCancellationStopsOnlyAnUnconfiguredRelay() async throws {
    let payload = Data(#"{"installation_id":"install-cancel","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let appURL = URL(string: "https://my.personastack.ai")!
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(appURL)

    for hasActiveConfig in [false, true] {
        let suite = "desktop-control-relay-idle-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: DesktopControlPreferenceKeys.relayEnabled(.production))
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []),
            credentials: SavedDesktopControlCredentialStore(installation: installation),
            connectionID: UUID(), installation: installation, connected: true,
            readiness: "ready", relayStateReader: DesktopControlRelayStateFixture(active: hasActiveConfig),
            preferences: preferences
        )

        await runtime.finishSetupIfIdle()

        #expect(runtime.gatewayConnected == hasActiveConfig)
        #expect(runtime.hasActiveInstallation == hasActiveConfig)
        #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)) == hasActiveConfig)
    }
}

@Test @MainActor func idleRelayStopsOnlyItsOwnedCuaAfterLastMapping() async throws {
    let payload = Data(#"{"installation_id":"install-cua-idle","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(URL(string: "https://my.personastack.ai")!)

    for (hasActiveConfig, ownsCua, expectedStops) in [(true, true, 0), (false, false, 0), (false, true, 1)] {
        let suite = "desktop-control-owned-cua-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: DesktopControlPreferenceKeys.relayEnabled(.production))
        var cuaStops = 0
        let runtime = DesktopControlRuntime.makeForTesting(
            installer: DesktopControlInstallerFixture(errors: []),
            credentials: SavedDesktopControlCredentialStore(installation: installation),
            connectionID: UUID(), installation: installation, connected: true,
            readiness: "ready", relayStateReader: DesktopControlRelayStateFixture(active: hasActiveConfig),
            preferences: preferences,
            ownedCuaService: ownsCua ? CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua")) : nil,
            stopCuaService: { _ in cuaStops += 1; return true }
        )

        await runtime.finishSetupIfIdle()

        #expect(cuaStops == expectedStops)
        #expect(runtime.gatewayConnected == hasActiveConfig)
        #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)) == hasActiveConfig)
    }
}

@Test @MainActor func idleRelayRetriesWhenOwnedCuaCannotStop() async throws {
    let payload = Data(#"{"installation_id":"install-cua-stop-failure","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(URL(string: "https://my.personastack.ai")!)
    let suite = "desktop-control-cua-stop-failure-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: DesktopControlPreferenceKeys.relayEnabled(.production))
    var cuaStops = 0
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        connectionID: UUID(), installation: installation, connected: true,
        readiness: "ready", relayStateReader: DesktopControlRelayStateFixture(active: false),
        preferences: preferences, ownedCuaService: CuaEmbeddedService(executableURL: URL(fileURLWithPath: "/fake/cua")),
        stopCuaService: { _ in cuaStops += 1; return false }
    )

    await runtime.finishSetupIfIdle()

    #expect(cuaStops == 1)
    #expect(runtime.gatewayConnected)
    #expect(runtime.hasActiveInstallation)
    #expect(runtime.readiness == "cua_unavailable")
    #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)))
}

@Test @MainActor func idleRelayKeepsInstallationWhenExecutorCleanupFails() async throws {
    let payload = Data(#"{"installation_id":"install-idle-failure","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(URL(string: "https://my.personastack.ai")!)
    let suite = "desktop-control-idle-failure-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(true, forKey: DesktopControlPreferenceKeys.relayEnabled(.production))
    let executor = DesktopControlCommandExecutor(powerAssertion: .testFixture())
    let owner = DesktopControlTarget(installationID: installation.installationID, workspaceID: "workspace-a",
                                     configID: "config-a", personaID: "persona-a", runID: "run-a",
                                     generation: 1, configVersion: 1)
    let acquire = DesktopControlFrame(type: "command", requestID: "acquire-idle-failure", target: owner,
                                      operation: "desktop_control_acquire", arguments: .object([:]))
    #expect((await executor.handle(acquire, proxy: nil)).type == "result")
    executor.failNextCleanupForTesting()
    let runtime = DesktopControlRuntime.makeForTesting(
        installer: DesktopControlInstallerFixture(errors: []),
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        executor: executor, connectionID: UUID(), installation: installation, connected: true,
        readiness: "ready", relayStateReader: DesktopControlRelayStateFixture(active: false),
        preferences: preferences
    )

    await runtime.finishSetupIfIdle()

    #expect(runtime.gatewayConnected)
    #expect(runtime.hasActiveInstallation)
    #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)))
    #expect(runtime.readiness == "cua_unavailable")
}

@Test @MainActor func setupReplyBoundaryRetriesAfterPermissionGrantAndConnectsInstallation() async throws {
    let installationPayload = Data(#"{"installation_id":"installation-setup","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let appURL = URL(string: "https://my.personastack.ai")!
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: installationPayload)
    // Saved credentials carry the origin set by the enrollment commit path.
    try installation.bindEnvironment(appURL)
    let runtime = DesktopControlSetupRuntimeFixture()
    let enrollment = DesktopControlSetupEnrollmentFixture()
    let defaultsName = "desktop-control-setup-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: defaultsName))
    defer { preferences.removePersistentDomain(forName: defaultsName) }
    let manager = DesktopControlSetupManager(
        runtime: runtime,
        enrollment: enrollment,
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        preferences: preferences,
        configurationProvider: { .production },
        permissionPresenter: FinishedDesktopControlPermissionFixture()
    )
    let page = DesktopControlSetupManager.Page(appURL: appURL)
    let scope = "workspace-setup-session"
    page.setupScope.synchronize(scope)
    _ = try await manager.apply(.permissions(scope: scope, phase: .open, message: nil), page: page)
    let setupGeneration = page.setupScope.generation
    let body: [String: Any] = [
        "version": "1", "action": "prepare", "scope": scope,
        "enrollment_ticket": String(repeating: "a", count: 43),
    ]

    func sendSetupMessage() async -> (error: String?, ok: Bool, installationID: String?, cuaReady: Bool, gatewayConnected: Bool, relayPaused: Bool) {
        await withCheckedContinuation { continuation in
            manager.dispatch(body, page: page) { value, error in
                let response = value as? [String: Any]
                continuation.resume(returning: (
                    error: error,
                    ok: response?["ok"] as? Bool ?? false,
                    installationID: response?["installation_id"] as? String,
                    cuaReady: response?["cua_ready"] as? Bool ?? false,
                    gatewayConnected: response?["gateway_connected"] as? Bool ?? false,
                    relayPaused: response?["relay_paused"] as? Bool ?? true
                ))
            }
        }
    }

    let denied = await sendSetupMessage()
    #expect(denied.ok == false)
    #expect(denied.error == CuaMCPProxyError.permissionsRequired.localizedDescription)
    #expect(runtime.readiness == "permission_required")

    #expect(page.setupScope.generation == setupGeneration)
    #expect(page.setupScope.value == scope)
    #expect(await enrollment.readyInstallationIDs.isEmpty)
    #expect(await enrollment.attachedTicketInstallationIDs == [installation.installationID])
    #expect(runtime.disconnectCalls == 1)

    runtime.permissionGranted = true
    let retried = await sendSetupMessage()
    #expect(retried.error == nil)
    #expect(retried.ok)
    #expect(retried.installationID == installation.installationID)
    #expect(retried.cuaReady)
    #expect(retried.gatewayConnected)
    #expect(!retried.relayPaused)
    #expect(runtime.attempts == 2)
    #expect(runtime.nativeProbeCount == 1)
    #expect(runtime.repairAttempts == 0)
    #expect(runtime.connectedInstallationID == installation.installationID)
    #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)))
    #expect(!(preferences.bool(forKey: DesktopControlPreferenceKeys.relayPaused(.production))))
    #expect(await enrollment.readyInstallationIDs == [installation.installationID])
    #expect(await enrollment.attachedTicketInstallationIDs == [installation.installationID, installation.installationID])
    #expect(runtime.disconnectCalls == 2)
    #expect(page.setupScope.generation == setupGeneration)

    page.setupScope.synchronize("")
    let staleRetry = await sendSetupMessage()
    #expect(staleRetry.error == DesktopControlEnrollmentError.invalidRequest.localizedDescription)
    #expect(!staleRetry.ok)
    #expect(runtime.attempts == 2)
    #expect(await enrollment.readyInstallationIDs == [installation.installationID])
    #expect(await enrollment.attachedTicketInstallationIDs == [installation.installationID, installation.installationID])
    #expect(runtime.disconnectCalls == 2)
}

@Test @MainActor func setupEnrollmentDoesNotRequireLoginServiceOwner() async throws {
    let payload = Data(#"{"installation_id":"installation-approval","machine_credential":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","gateway_websocket_url":"wss://cluster-agent.personastack.ai/v1/desktop-control/ws"}"#.utf8)
    let appURL = URL(string: "https://my.personastack.ai")!
    var installation = try JSONDecoder().decode(DesktopControlInstallation.self, from: payload)
    try installation.bindEnvironment(appURL)
    let runtime = DesktopControlSetupRuntimeFixture()
    runtime.permissionGranted = true
    let enrollment = DesktopControlSetupEnrollmentFixture()
    let suite = "desktop-control-approval-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    let manager = DesktopControlSetupManager(
        runtime: runtime,
        enrollment: enrollment,
        credentials: SavedDesktopControlCredentialStore(installation: installation),
        preferences: preferences,
        configurationProvider: { .production },
        permissionPresenter: FinishedDesktopControlPermissionFixture()
    )
    let page = DesktopControlSetupManager.Page(appURL: appURL)
    page.setupScope.synchronize("workspace-setup-session")
    _ = try await manager.apply(.permissions(scope: "workspace-setup-session", phase: .open, message: nil), page: page)
    // Enrollment has no login-service dependency. Launch at Login belongs to
    // automatic checklist setup and may remain unavailable without blocking it.
    let response = try await manager.apply(.prepare(scope: "workspace-setup-session", enrollmentTicket: String(repeating: "a", count: 43)), page: page)
    #expect(response["installation_id"] as? String == installation.installationID)
    #expect(response["gateway_connected"] as? Bool == true)
    #expect(runtime.nativeProbeCount == 1)
    #expect(await enrollment.readyInstallationIDs == [installation.installationID])
    #expect(await enrollment.attachedTicketInstallationIDs == [installation.installationID])
    #expect(runtime.gatewayConnected)
    #expect(preferences.bool(forKey: DesktopControlPreferenceKeys.relayEnabled(.production)))
}

@Test @MainActor func cuaMinimumAccessibilitySetupResumesWithoutScreenCaptureAndRejectsRevocation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-minimum-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("screen-denied"))
    let executable = try makeRuntimeDriverFixture(root)
    var accessibilityGranted = true
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: credentials, sessionLockState: .unlocked, hostPermissions: { (accessibilityGranted, false) })
    do {
        await runtime.waitForSessionLockChangeForTesting()
        try await runtime.prepareCuaPermissions()
        let target = RuntimeInputTarget(root: root)
        try await runtime.verifyCuaInputForPermissions(target: target)
        #expect(target.clickCount == 1 && target.text == target.expectedText)
        #expect(credentials.readCount == 0)
        try await runtime.resumeForSetup(generation: runtime.beginResume())
        #expect(runtime.isCuaReady() && runtime.readiness == "ready")
        #expect(credentials.readCount == 1)
        #expect(!(try runtimeFixtureCalls(root)).contains("get_desktop_state"))
        await #expect(throws: CuaMCPProxyError.permissionsRequired) { try await runtime.verifyCuaCapabilitiesForPermissions() }
        #expect(runtime.isCuaReady())
        #expect(!(try runtimeFixtureCalls(root)).contains("get_desktop_state"))
        try await runtime.resumeForSetup(generation: runtime.beginResume())
        #expect(runtime.isCuaReady())
        accessibilityGranted = false
        #expect(!runtime.isCuaReady())
        await #expect(throws: CuaMCPProxyError.permissionsRequired) {
            try await runtime.resumeForSetup(generation: runtime.beginResume())
        }
        #expect(!runtime.isCuaReady())
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

@Test @MainActor func cuaCancelledOptionalCaptureStopsAfterPermissionReadback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-cancel-capture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: PermissionPreparationCredentialStore(installation: nil), sessionLockState: .unlocked,
        hostPermissions: { (true, true) })
    do {
        await runtime.waitForSessionLockChangeForTesting()
        try await runtime.resumeForSetup(generation: runtime.beginResume())
        #expect(runtime.isCuaReady())
        let pause = root.appendingPathComponent("pause-permissions")
        try Data().write(to: pause)
        let optional = Task { try await runtime.verifyCuaCapabilitiesForPermissions() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("permissions-waiting").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("permissions-waiting").path))
        optional.cancel()
        try FileManager.default.removeItem(at: pause)
        do { try await optional.value; Issue.record("Cancelled capture must not complete") }
        catch { #expect(error is CancellationError || (error as? CuaMCPProxyError) == .interrupted) }
        #expect(!(try runtimeFixtureCalls(root)).contains("get_desktop_state"))
        #expect(runtime.isCuaReady())
        await runtime.shutdownForQuit()
    } catch { await runtime.shutdownForQuit(); throw error }
}

private actor SuspendedPermissionStartupInstaller: DesktopControlDriverInstalling {
    let executable: URL
    private(set) var calls = 0
    private var pending: CheckedContinuation<Void, Never>?
    init(executable: URL) { self.executable = executable }
    func validateOrInstall(repair: Bool, commitManagedInstall: (@MainActor @Sendable (URL, URL, Bool) throws -> Void)?) async throws -> CuaDriverInstallation {
        calls += 1
        if calls == 1 { await withCheckedContinuation { pending = $0 } }
        return CuaDriverInstallation(applicationURL: executable.deletingLastPathComponent(), executableURL: executable,
                                    version: CuaDriverCompatibility.version, toolNames: CuaDriverCompatibility.requiredTools)
    }
    var isSuspended: Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
}

@MainActor private final class StartupPermissionChecklistAdapter: DesktopPermissionChecklistAdapting {
    let runtime: DesktopControlRuntime
    let restart: Bool
    init(runtime: DesktopControlRuntime, restart: Bool = false) {
        self.runtime = runtime
        self.restart = restart
    }
    func observe(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        .init(permission == .accessibility ? .ready : .notGranted, detail: "Fixture", requiresVerification: permission == .accessibility, verified: permission == .accessibility)
    }
    func setup(_ permission: DesktopPermissionID) async -> DesktopPermissionObservation {
        do {
            if restart { try await runtime.restartCuaAfterPermissionChange() }
            else { try await runtime.prepareCuaPermissions() }
            return .init(.ready, detail: "Started")
        } catch { return .init(.checking, detail: "Cancelled") }
    }
}

@Test @MainActor func cuaFinishRetiresCancelledInstallerBeforeSuccessorStartup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-cancel-installer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try makeRuntimeDriverFixture(root)
    let installer = SuspendedPermissionStartupInstaller(executable: executable)
    let credentials = PermissionPreparationCredentialStore(installation: nil)
    let runtime = DesktopControlRuntime.makeForTesting(installer: installer, credentials: credentials,
        readiness: "paused", paused: true, sessionLockState: .unlocked, hostPermissions: { (true, false) })
    await runtime.waitForSessionLockChangeForTesting()
    let model = DesktopPermissionChecklistCoordinator(adapter: StartupPermissionChecklistAdapter(runtime: runtime))
    model.open()
    await model.refresh()
    model.setup(.screenRecording)
    for _ in 0..<100 {
        if await installer.isSuspended { break }
        await Task.yield()
    }
    #expect(await installer.isSuspended)
    model.finish()
    #expect(model.isFinishing && runtime.readiness == "paused")
    let successor = Task { try await runtime.resumeForSetup(generation: runtime.beginResume()) }
    for _ in 0..<20 { await Task.yield() }
    #expect(await installer.calls == 1)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("daemon-starts").path))
    await installer.release()
    do {
        try await successor.value
        #expect(await installer.calls == 2)
        #expect(runtime.isCuaReady() && runtime.readiness == "ready")
        #expect(credentials.readCount == 1)
        #expect(try runtimeFixtureCalls(root) == ["health_report", "check_permissions", "get_accessibility_tree"])
        model.cancel()
        await runtime.shutdownForQuit()
    } catch { model.cancel(); await runtime.shutdownForQuit(); throw error }
}

@Test(arguments: ["proxy", "daemon"]) @MainActor
func cuaFinishWaitsForCancelledStartupCleanupBeforeSuccessorUsesDaemon(_ stage: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-cancel-\(stage)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let pause = root.appendingPathComponent("pause-\(stage)-start")
    let cleanup = root.appendingPathComponent("pause-daemon-cleanup")
    try Data().write(to: pause)
    if stage == "daemon" { try Data().write(to: cleanup) }
    let executable = try makeRuntimeDriverFixture(root)
    let runtime = DesktopControlRuntime.makeForTesting(installer: EmbeddedRuntimeDriverFixture(executable: executable),
        credentials: PermissionPreparationCredentialStore(installation: nil), readiness: "paused", paused: true,
        sessionLockState: .unlocked, hostPermissions: { (true, false) })
    await runtime.waitForSessionLockChangeForTesting()
    let model = DesktopPermissionChecklistCoordinator(adapter: StartupPermissionChecklistAdapter(runtime: runtime))
    model.open()
    await model.refresh()
    model.setup(.screenRecording)
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("\(stage)-starting").path) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(stage)-starting").path))
    model.finish()
    let successor = Task { try await runtime.resumeForSetup(generation: runtime.beginResume()) }
    if stage == "daemon" {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("daemon-stopping").path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("daemon-stopping").path))
        let starts = try String(contentsOf: root.appendingPathComponent("daemon-starts"), encoding: .utf8)
        #expect(starts.split(separator: "\n").count == 1)
        try FileManager.default.removeItem(at: cleanup)
    }
    try FileManager.default.removeItem(at: pause)
    do {
        try await successor.value
        #expect(runtime.isCuaReady() && runtime.readiness == "ready")
        #expect(model.isFinishing)
        let calls = try runtimeFixtureCalls(root)
        #expect(calls == ["health_report", "check_permissions", "get_accessibility_tree"])
        for _ in 0..<10 { await Task.yield() }
        #expect(runtime.isCuaReady())
        model.cancel()
        await runtime.shutdownForQuit()
    } catch { model.cancel(); await runtime.shutdownForQuit(); throw error }
}
