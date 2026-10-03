"""Source wiring contracts for SwiftUI menus, not rendered-menu acceptance."""

from pathlib import Path
import re
import unittest


SOURCES = Path(__file__).resolve().parents[2] / "Sources" / "PersonaStack"


def block(source, marker):
    """Read a menu declaration's brace-delimited block, ignoring string braces."""
    start = source.index("{", source.index(marker))
    depth = 0
    quoted = False
    escaped = False
    for index in range(start, len(source)):
        char = source[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"Unclosed menu block: {marker}")


class MenuBarLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.menu = (SOURCES / "DesktopControlMenu.swift").read_text()
        cls.updater = (SOURCES / "DesktopUpdater.swift").read_text()
        cls.app = (SOURCES / "PersonaStackApp.swift").read_text()

    def test_frequent_actions_precede_submenus_and_quit_is_last(self):
        body = block(self.menu, "var body: some View")
        markers = [
            'Button("Open PersonaStack")',
            "connectionStatus",
            "Text(loginItemError)",
            "Button(action.title)",
            'Menu("Desktop Control")',
            'Menu("Settings")',
            'Menu("Updates")',
            'Button("Quit PersonaStack")',
        ]
        positions = [body.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(body.count("toggleRelay()"), 1)
        self.assertIn(".disabled(!action.isEnabled)", body)
        self.assertIn("NSApp.terminate(nil)", block(body, 'Button("Quit PersonaStack")'))
        self.assertNotIn('Button(', body[positions[-1] + len(markers[-1]):])
        self.assertNotIn('Text("PersonaStack")', body)

    def test_setup_and_recovery_keep_their_existing_handlers_and_guards(self):
        body = block(self.menu, "var body: some View")
        self.assertIn("desktopControlActions", block(body, 'Menu("Desktop Control")'))
        controls = block(self.menu, "private var desktopControlActions")
        self.assertIn("DesktopPermissionChecklist.shared.window.presentForRepair()",
                      block(controls, 'Button("Permissions and Setup…")'))
        self.assertNotIn("requiresForegroundSessionConfirmation", controls)
        self.assertNotIn("confirmForegroundSession", controls)
        self.assertNotIn('Button("Confirm This Mac Is Unlocked")', controls)
        self.assertIn("relayEnabled || DesktopControlRuntime.shared.hasPendingEnvironmentSwitch", controls)
        self.assertIn("Task { await repairCua() }", controls)
        self.assertIn(".disabled(status.isRepairing || DesktopControlRuntime.shared.isDisconnecting)", controls)
        self.assertIn('Button("Disconnect This Mac…", role: .destructive)', controls)
        self.assertIn("confirmDisconnect()", controls)
        confirmation = block(self.menu, "private func confirmDisconnect()")
        self.assertIn("alert.runModal() == .alertFirstButtonReturn", confirmation)
        self.assertIn("Task { await disconnectRelay() }", confirmation)
        self.assertIn("Text(relayError)", controls)
        self.assertIn("Text(repairError)", controls)

    def test_settings_own_configuration_and_update_preference(self):
        body = block(self.menu, "var body: some View")
        settings = block(body, 'Menu("Settings")')
        self.assertIn("DesktopConcernNotificationsMenuItem()", settings)
        self.assertIn("DesktopServerSettingsMenuItem()", settings)
        self.assertIn("registerLoginItem()", block(settings, 'Button("Launch at Login")'))
        self.assertIn(".disabled(DesktopLoginItemRegistration.loginStatus() == .enabled)", settings)
        self.assertNotIn("Text(loginItemError)", settings)
        self.assertIn("DesktopAutomaticUpdatesMenuItem()", settings)
        preference = block(self.updater, "struct DesktopAutomaticUpdatesMenuItem")
        self.assertIn("get: { updater.automaticallyDownloadsUpdates }", preference)
        self.assertIn("set: { updater.automaticallyDownloadsUpdates = $0 }", preference)
        self.assertIn(".disabled(!updater.isAvailable)", preference)

    def test_updates_preserve_check_download_and_prepared_restart_actions(self):
        updates = block(self.updater, "struct DesktopUpdatesMenuSection")
        for action in ("updater.checkForUpdates()", "updater.downloadLatestUpdate()",
                       "updater.restartToInstall()", "updater.dismissReadyToast()"):
            self.assertIn(action, updates)
        self.assertIn("if updater.isReady", updates)
        self.assertIn("if updater.updateAvailable && !updater.isReady", updates)
        self.assertIn(".disabled(!updater.isAvailable || !updater.canCheckForUpdates || updater.isChecking)", updates)
        self.assertIn("updater.isInformationalUpdate", updates)
        self.assertIn("updater.isWaitingForApproval", updates)
        self.assertIn("updater.applicationsInstallInstruction", updates)
        self.assertIn("updater.statusMessage", updates)
        self.assertNotIn('Toggle(', updates)

    def test_menu_bar_has_one_owner_with_no_actions_appended_after_quit(self):
        extra = block(self.app, "MenuBarExtra {")
        self.assertEqual(re.findall(r"\b\w+\(\)", extra), ["DesktopControlMenu()"])


if __name__ == "__main__":
    unittest.main()
