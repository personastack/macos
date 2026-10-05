#!/usr/bin/env python3
"""Opt-in LaunchServices regression using the production supervisor in an owned app."""
import os
import pathlib
import plistlib
import signal
import subprocess
import tempfile
import time
import unittest
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
STUBS = r'''
import Foundation
@MainActor enum DesktopUpdater { static let foregroundUpdateRelaunchKey = "probe-update" }
struct LaunchConfiguration {
    static func selectedEnvironment() throws -> LaunchConfiguration { LaunchConfiguration() }
}
enum DesktopControlPreferenceKeys {
    static func relayEnabled(_ configuration: LaunchConfiguration) -> String { "probe-relay" }
    static func relayPaused(_ configuration: LaunchConfiguration) -> String { "probe-paused" }
}
@MainActor final class DesktopLockedControlSupervisorHost {
    static func production(pinnedReleaseCertificate: Data) -> DesktopLockedControlSupervisorHost {
        DesktopLockedControlSupervisorHost()
    }
    func start() throws { fatalError("The fixture must never start a control listener") }
}
'''
MAIN = r'''
import AppKit
import SwiftUI
@main @MainActor enum Entry {
    static func main() {
        if DesktopCrashRecoverySupervisor.isSupervisorInvocation() {
            DesktopCrashRecoverySupervisor(shouldRestartForRelay: { true }).run()
        }
        if !CommandLine.arguments.contains(DesktopCrashRecoverySupervisor.recoveryLaunchArgument) {
            DesktopCrashRecoveryPolicy.resumeAfterExplicitLaunch()
        }
        FixtureApp.main()
    }
}
@MainActor struct FixtureApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        try! String(getpid()).write(to: directory.appendingPathComponent("main.pid"),
                                   atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stay").path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                DesktopCrashRecoveryPolicy.recordTerminationIntent(isUpdateRelaunch: false)
                NSApp.terminate(nil)
            }
        }
    }
    var body: some Scene {
        MenuBarExtra("Supervisor Regression", systemImage: "questionmark") {
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
'''


def wait_for(predicate, message, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(message)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


@unittest.skipUnless(os.environ.get("PERSONASTACK_NATIVE_LIFECYCLE_ACCEPTANCE") == "1",
                     "Opt-in native LaunchServices acceptance")
class SupervisorRelaunchTests(unittest.TestCase):
    def test_quit_reopens_while_headless_supervisor_keeps_monitoring(self):
        identifier = "test.personastack.supervisor." + uuid.uuid4().hex
        with tempfile.TemporaryDirectory(prefix="personastack-supervisor-") as temporary:
            directory = pathlib.Path(temporary)
            app = directory / "Supervisor Regression.app"
            executable = app / "Contents/MacOS/Probe"
            executable.parent.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "Probe",
                "CFBundleName": "Supervisor Regression", "CFBundlePackageType": "APPL",
            }))
            sources = []
            for name in ("PersonaStack/DesktopCrashRecoverySupervisor.swift",
                         "PersonaStackCore/DesktopCrashRecoveryPolicy.swift"):
                source = directory / pathlib.Path(name).name
                source.write_text((ROOT / "Sources" / name).read_text()
                                  .replace("import PersonaStackCore\n", ""))
                sources.append(str(source))
            for name, contents in (("Stubs.swift", STUBS), ("Entry.swift", MAIN)):
                source = directory / name
                source.write_text(contents)
                sources.append(str(source))
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", *sources,
                            "-o", str(executable)], check=True, timeout=60)
            environment = dict(os.environ, PROBE_DIRECTORY=str(directory))
            supervisor = subprocess.Popen([str(executable), "--personastack-crash-supervisor"],
                                          env=environment, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL)
            owned_pids = set()
            pid_file = directory / "main.pid"

            def new_main():
                if not pid_file.exists():
                    return None
                pid = int(pid_file.read_text())
                if pid in owned_pids:
                    return None
                owned_pids.add(pid)
                return pid

            def registered():
                result = subprocess.run(["lsappinfo", "find", "bundleID=" + identifier],
                                        capture_output=True, text=True, check=True, timeout=5)
                return bool(result.stdout.strip())

            try:
                # The production supervisor launches and observes its first GUI child.
                first = wait_for(new_main, "Supervisor did not launch the GUI")
                wait_for(lambda: not alive(first), "Intentional Quit did not exit")
                self.assertIsNone(supervisor.poll())
                wait_for(lambda: not registered(), "Supervisor retained the GUI app identity", timeout=3)
                for _ in range(3):
                    subprocess.run(["open", str(app)], env=environment,
                                   check=True, capture_output=True, text=True, timeout=10)
                    pid = wait_for(new_main, "LaunchServices did not reopen the GUI")
                    wait_for(lambda: not alive(pid), "Reopened GUI did not quit")
                    self.assertIsNone(supervisor.poll())
                    wait_for(lambda: not registered(), "Quit left an app registration behind", timeout=3)

                # Crash the directly reopened accessory GUI while retaining the
                # same supervisor. Both external adoption and child exits matter.
                (directory / "stay").touch()
                subprocess.run(["open", str(app)], env=environment,
                               check=True, capture_output=True, timeout=10)
                live = wait_for(new_main, "GUI did not resume after intentional Quit")
                os.kill(live, signal.SIGKILL)
                child = wait_for(new_main, "Supervisor lost the directly reopened accessory GUI")
                os.kill(child, signal.SIGKILL)
                # This is the second crash, so production backoff is ten seconds.
                replacement = wait_for(new_main, "Headless supervisor lost child crash monitoring", timeout=15)
                self.assertTrue(alive(replacement))
                self.assertIsNone(supervisor.poll())
            finally:
                if supervisor.poll() is None:
                    supervisor.terminate()
                    supervisor.wait(timeout=5)
                for pid in owned_pids:
                    if alive(pid):
                        os.kill(pid, signal.SIGTERM)
                subprocess.run(["defaults", "delete", identifier],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
