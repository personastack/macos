# Hermes and OpenClaw on this Mac

Install and configure your runtime first. PersonaStack uses its existing profiles and AI provider settings. The Mac must be awake and signed in to receive work.

## Connect a profile

1. Open the persona's settings in the PersonaStack macOS app.
2. Choose the Hermes or OpenClaw connection action.
3. Select **Enable background work and find profiles**. Approve the background login item if macOS requests it.
4. Select the installed profile. Choose **Connect profile**. If OpenClaw has several agents, choose the agent in the native picker. A sole agent is selected automatically. Review the native confirmation before continuing.
5. Wait for the connection's readiness report. Use **Send test wake** for a bounded assigned task. The test may use your AI provider.

One profile connects to one persona. Repeat these steps with other profiles to connect several personas on the same Mac. Profiles already linked elsewhere cannot be selected. OpenClaw agents that share one profile also share its connection. Assigned work uses the selected agent. Configure an agent in OpenClaw first if the profile explicitly has none. PersonaStack currently requires strict JSON profile configs. JSON5 profiles are reported as unavailable and remain unchanged.

The connection controls require the macOS app. A connection on another Mac is shown as read-only on this Mac. The ordinary CLI setup remains available for Codex, Claude Code, OpenCode and Pi.

## Background work and status

Closing app windows or choosing Quit leaves enabled background agents running. Use the app's **Background Agents** menu to stop them. Finish assigned work or use the persona's existing **Stop** action first. **Review Login Items…** opens the macOS approval settings.

Connection status reports readiness and work assigned by PersonaStack. It does not report other work started inside your runtime. A ready connection does not prove the entire native profile is idle. Sleep and sign-out make the Mac unavailable for new work.

**Check connection** reads readiness. **Repair** requests native consent before enabling the selected Hermes MCP toolset or starting the selected runtime. It cannot renew rejected PersonaStack credentials. If the app asks you to reconnect, use **Disconnect** for that connection and connect the profile again. Runtime or AI provider authorization stays in the runtime's own setup.

## Migrate an existing Connector

Select the existing connection in persona settings. Choose **Migrate profile** after profile discovery. The app waits for assigned work to finish or asks you to stop it. It then asks for **Pause and migrate** consent before stopping the exact old supervisor and replacing the connection.

Keep the old configuration backup. Successful migration restores the persona's earlier pause state. A previously paused persona stays paused. Resume it explicitly before testing a wake.

Failure after the old connection is revoked leaves the persona paused. Select the same persona and profile to resume a retained migration. If the helper restarted or the capture expired, the app provides native instructions for reviewing the backup and exact old entry. Do not restart the revoked Connector. Root-service removal requires an explicit administrator step. Linux and pre-login installations need a separate agreed disposition.

## Disconnect or replace the app

**Disconnect** affects the selected profile only. Review the confirmation. Active assigned work requires explicit Stop consent. The app checks both cloud and local idle state before revoking the connection. It removes only its matching owned tools entry. Edited or conflicting entries need manual review. Other profiles and third-party runtimes remain installed.

Use the normal updater for app replacement. It waits for assigned work and blocks an unfinished migration. Before manually replacing the app bundle, finish assigned work and choose **Stop Background Agents**. Start the new app and enable background agents again. Do not overwrite a running helper's app bundle.

Configuration backups and native runtime files can remain after disconnection. Review them locally before removing anything.
