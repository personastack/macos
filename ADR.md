# 2026-09-28 - Exclusive Desktop Control installation

- Decision: Eric limits each local installation to one PersonaStack account and one integration configuration at a time. App updates preserve its Keychain installation ID. A fresh attachment fails until the existing integration is removed. Disabling it keeps the reservation. The API owns enforcement and account assignment.

# Architecture decisions

- 2026-09-15: The macOS client is a thin native SwiftUI and WebKit shell for the existing `my.personastack.ai` website. It does not add a second authentication, API, datastore, or product-state authority. The first release is unsigned and distributed as a GitHub Release disk image.
- 2026-09-15: The macOS client accepts one main-frame `my.personastack.ai` WebKit bridge event for new concerns. The event is schema-checked and carries no concern or account data. The client owns only generic notification presentation while it is running.
- 2026-09-15: The desktop source and primary GitHub release remain private. Every tagged installer is also published to a versioned public `personastack/homebrew-tap` Git tag, which owns the Homebrew cask and its public immutable download URL.
- 2026-09-23: Desktop Control expands the macOS client from a presentation-only shell into the per-user native execution/transport owner while preserving API and gateway authority. Use one API-enrolled installation identity, one outbound connection to `agent-gateway`, one shared local control owner, and the pinned standalone signed `CuaDriver.app` identity for GUI permission attribution. Keep file/process operations native and finite. Do not expose arbitrary local MCP tools, workspace-separated desktop illusions, durable action replay, or a new cloud service.
