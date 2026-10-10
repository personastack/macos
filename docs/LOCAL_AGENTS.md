# Hermes and OpenClaw on this Mac

Install and configure your runtime first. PersonaStack uses its existing profiles and AI provider settings. The Mac must be awake and signed in to receive work.

## Connect a profile

1. Open the persona's settings in the PersonaStack macOS app.
2. Choose the Hermes or OpenClaw connection action.
3. Select **Enable background work and find profiles**. Approve the background login item if macOS requests it.
4. Select the installed profile. Choose **Connect profile**. If OpenClaw has several agents, choose the agent in the native picker. A sole agent is selected automatically. Review the native confirmation before continuing.
5. If the Hermes shared host needs startup, review its separate native approval. Enabling its gateway API and starting Hermes can activate configured messaging services and scheduled jobs for other profiles. PersonaStack connects only the selected profile. Cancel leaves the host configuration unchanged.
6. If OpenClaw MCP Apps is disabled, review its separate native approval. Enabling Apps adds HTML App capability and an extra local sandbox listener. Repair may restart the selected gateway. Cancel leaves the profile configuration unchanged. Approve gateway Repair separately when asked.
7. Wait for the connection's readiness report. Use **Send test wake** for a bounded assigned task. For Hermes, also ask the persona in chat to call `my_persona_info` and check the returned identity. These tasks may use your AI provider.

One profile connects to one persona. Repeat these steps with other profiles to connect several personas on the same Mac. Profiles already linked elsewhere cannot be selected. OpenClaw agents that share one profile also share its connection. Assigned work uses the selected agent. Configure an agent in OpenClaw first if the profile explicitly has none. PersonaStack currently requires strict JSON profile configs. JSON5 profiles are reported as unavailable and remain unchanged.

The connection controls require the macOS app. A connection on another Mac is shown as read-only on this Mac. The ordinary CLI setup remains available for Codex, Claude Code, OpenCode and Pi.

## Background work and status

Closing app windows or choosing Quit leaves enabled background agents running. Use the app's **Background Agents** menu to stop them. Finish assigned work or use the persona's existing **Stop** action first. **Review Login Items…** opens the macOS approval settings.

Connection status reports readiness and work assigned by PersonaStack. It does not report other work started inside your runtime. A ready connection does not prove the entire native profile is idle. Sleep and sign-out make the Mac unavailable for new work.

Hermes readiness checks the selected profile's tools configuration, authenticated gateway control and direct PersonaStack MCP access. It does not prove that Hermes has loaded those tools. Complete a test wake that calls a PersonaStack tool before relying on the connection for assigned work. OpenClaw readiness also checks the selected agent's effective tools.

**Check connection** reads readiness. **Repair** requests native consent before enabling the selected Hermes MCP toolset or starting the selected OpenClaw gateway. Hermes uses one shared host on this Mac. Starting that host and enabling its gateway API requires separate approval. It can activate configured messaging services and scheduled jobs for other profiles. An eligible running host can serve the selected profile without startup approval. Disconnecting leaves that shared host running. OpenClaw MCP Apps requires separate approval when disabled. This approval belongs to the selected profile. It does not approve another profile or replace gateway restart consent. Apps stays enabled after disconnecting from PersonaStack. **Repair** cannot renew rejected PersonaStack credentials. If the app asks you to reconnect, use **Disconnect** for that connection and connect the profile again. Runtime or AI provider authorization stays in the runtime's own setup.

PersonaStack does not restart or take over a running Hermes host whose loopback API cannot be attached safely. The native prompt provides manual setup guidance. Configure that host through Hermes, then choose **Repair**.

A gateway installed with plain `openclaw gateway install` may lack exact profile environment fields. PersonaStack leaves an unverified listener untouched. Stop that preexisting gateway through OpenClaw, then choose **Repair** and approve starting the selected profile. Helper-started gateways and native installs with explicit `--profile default` or a named profile retain the required scope fields.

## Migrate an existing Connector

Select the existing connection in persona settings. Choose **Migrate profile** after profile discovery. The app waits for assigned work to finish or asks you to stop it. It then asks for **Pause and migrate** consent before stopping the exact old supervisor and replacing the connection.

Keep the old configuration backup. Successful migration restores the persona's earlier pause state. A previously paused persona stays paused. Resume it explicitly before testing a wake.

Failure after the old connection is revoked leaves the persona paused. Select the same persona and profile to resume a retained migration. If the helper restarted or the capture expired, the app provides native instructions for reviewing the backup and exact old entry. Do not restart the revoked Connector. Root-service removal requires an explicit administrator step. Linux and pre-login installations need a separate agreed disposition.

## Disconnect or replace the app

**Disconnect** affects the selected profile only. Review the confirmation. Active assigned work requires explicit Stop consent. The app checks both cloud and local idle state before revoking the connection. It removes only its matching owned tools entry. Edited or conflicting entries need manual review. Other profiles and third-party runtimes remain installed.

Use the normal updater for app replacement. It waits for assigned work and blocks an unfinished migration. Before manually replacing the app bundle, finish assigned work and choose **Stop Background Agents**. Start the new app and enable background agents again. Do not overwrite a running helper's app bundle.

Configuration backups and native runtime files can remain after disconnection. Review them locally before removing anything.
