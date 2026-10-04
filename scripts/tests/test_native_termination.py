#!/usr/bin/env python3
"""Exceptional AppKit acceptance. No user app, permission or update changes."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
# Compile the production delegate unchanged. Stubs stand in for app owners
# outside termination scheduling, so the probe never enrolls or opens content.
STUBS = r'''
import AppKit
@MainActor final class LocalRunManager {
    static let shared = LocalRunManager()
    var hasActiveSessions = false
    func shutdown(waitForRetry: Bool) async -> Bool { true }
    func showQuitRecovery() {}
}
@MainActor final class DesktopControlRuntime {
    static let shared = DesktopControlRuntime()
    func shutdownForQuit() async {}
}
@MainActor enum DesktopCrashRecoveryPolicy {
    static func recordTerminationIntent(isUpdateRelaunch: Bool, preferences: UserDefaults) {}
}
@MainActor enum DesktopLoginItemRegistration { static func enableOnFirstLaunch() {} }
@MainActor final class DesktopNotificationCoordinator {
    static let shared = DesktopNotificationCoordinator()
    func install() {}
}
@MainActor final class MainWebViewHost { static let shared = MainWebViewHost() }
@MainActor final class DesktopUpdater {
    static let shared = DesktopUpdater()
    static let foregroundUpdateRelaunchKey = "probe-update"
    func start() {}
    func applicationWillTerminate() {}
}
@MainActor final class DesktopApplicationRestart {
    static let foregroundArgument = "probe-relaunch"
    static let shared = DesktopApplicationRestart()
    func cancelPendingRestart() {}
}
'''
MAIN = r'''
import AppKit
func trace(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let deadline = CommandLine.arguments.contains("deadline")
let delegate = PersonaStackTerminationDelegate(shutdown: {
    trace("cleanup-started")
    if deadline { try? await Task.sleep(for: .seconds(5)) }
    else { try? await Task.sleep(for: .milliseconds(30)); trace("cleanup-completed") }
    return true
}, terminate: { sender in
    trace("exit-admitted")
    sender.terminate(nil)
}, timeout: .milliseconds(100))
app.delegate = delegate
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    app.terminate(nil)
    trace("initial-quit-returned")
}
app.run()
'''

with tempfile.TemporaryDirectory(prefix="personastack-termination-") as temporary:
    directory = pathlib.Path(temporary)
    delegate = ROOT / "Sources/PersonaStack/PersonaStackTerminationDelegate.swift"
    source = delegate.read_text().replace("import PersonaStackCore\n", "")
    (directory / "Delegate.swift").write_text(source)
    (directory / "Stubs.swift").write_text(STUBS)
    (directory / "main.swift").write_text(MAIN)
    executable = directory / "probe"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", *map(str, directory.glob("*.swift")),
                    "-o", str(executable)], check=True, timeout=60)
    for mode in ("cleanup", "deadline"):
        # subprocess.run kills only this owned probe if the deadline expires.
        result = subprocess.run([str(executable), mode], capture_output=True, text=True, timeout=3, check=True)
        assert "initial-quit-returned" in result.stdout, result.stdout
        assert "cleanup-started" in result.stdout, result.stdout
        assert result.stdout.count("exit-admitted") == 1, result.stdout
        if mode == "cleanup":
            assert "cleanup-completed" in result.stdout, result.stdout
        else:
            assert "cleanup-completed" not in result.stdout, result.stdout
        print(f"PASS real NSApplication.terminate: {mode}")
