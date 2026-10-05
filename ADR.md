# 2026-09-28 - Exclusive Desktop Control installation

- Decision: Eric limits each local installation to one PersonaStack account and one integration configuration at a time across all workspaces. App updates and Disconnect preserve the Keychain installation ID and machine credential. Explicit setup first revokes the local session, then machine-proven API attachment replaces the prior configuration and persona bindings. Disabling a configuration keeps the installation reserved. The installation ID is a locator and never authorizes deletion. The API owns enforcement and account assignment.

# Architecture decisions

- 2026-09-15: The macOS client is a thin native SwiftUI and WebKit shell for the existing `my.personastack.ai` website. It does not add a second authentication, API, datastore, or product-state authority. The first release is unsigned and distributed as a GitHub Release disk image.
- 2026-09-15: The macOS client accepts one main-frame `my.personastack.ai` WebKit bridge event for new concerns. The event is schema-checked and carries no concern or account data. The client owns only generic notification presentation while it is running.
- 2026-09-15: The desktop source and primary GitHub release remain private. Every tagged installer is also published to a versioned public `personastack/homebrew-tap` Git tag, which owns the Homebrew cask and its public immutable download URL.
- 2026-09-23: Desktop Control expands the macOS client from a presentation-only shell into the per-user native execution/transport owner while preserving API and gateway authority. Use one API-enrolled installation identity, one outbound connection to `agent-gateway`, one shared local control owner, and the pinned standalone signed `CuaDriver.app` identity for GUI permission attribution. Keep file/process operations native and finite. Do not expose arbitrary local MCP tools, workspace-separated desktop illusions, durable action replay, or a new cloud service.

# 2026-10-04 - Optional browser setup

- Decision: Eric makes Set up browsers optional. A Skip button lets the user continue without detected browser settings. Missing browser permissions must not block setup completion or general desktop readiness. Browser-specific operations keep their existing permission and consent checks.

# 2026-10-02 - One PersonaStack installation

- Decision: Eric requires our locked-control component to be part of the main PersonaStack install. The main signed package installs the app and component together. Desktop Control setup verifies the installation without launching a separate helper installer. Unsigned local builds retain the signing boundary and report locked control as unavailable.
