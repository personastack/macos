# PersonaStack for macOS specification

## Purpose

PersonaStack for macOS presents a selected PersonaStack web surface in a dedicated native macOS application window.

## Authority

- `my.personastack.ai` owns the hosted browser experience, cookies, public OAuth callbacks, and browser-facing composition.
- `personastack-api` owns identity, authorization, and product state.
- This client owns the macOS application bundle, WebKit configuration, native window behavior, local harness configuration through each CLI plugin manager, and installer packaging. It does not gain a second API, login, authorization, or product-state authority.

## Version 0.1.0 behavior

- Start at the valid HTTP(S) URL in the packaged `PersonaStackDefaultURL` value. Public packages default to `https://my.personastack.ai/user/personas`. An absent or invalid packaged value falls back to that production URL.
- Accept `--personastack-url <http-or-https-url>` at startup to override the initial URL for testing.
- Keep user-selected navigation on the override host in the app. Keep native bridge events restricted to approved PersonaStack hosts.
- Persist site data in the app's default WebKit data store.
- Keep Personastack-origin navigation in the app.
- Open user-selected external links and new windows in the default browser.
- Keep `https://accounts.google.com` OAuth popups in a native child window so Google Sign-In can return to the embedded app.
- Allow automated top-level redirects to preserve existing OAuth callback flows.
- Download non-displayable responses to the user's Downloads directory.
- Expose no native JavaScript bridge, local API, credentials, or direct PersonaStack service connection.

## Version 0.1.3 behavior

- Request macOS notification permission when the application opens.
- Accept only the main-frame PersonaStack app-host native bridge payload `{ "version": "1", "event": "created" }`.
- Post a generic native notification when a new concern arrives while the app is running.
- Do not pass concern text, concern IDs, workspace IDs, user IDs, credentials, or other product data through the bridge.

## Version 0.1.4 behavior

- Use a transparent full-size native title bar so hosted content fills the window beneath the standard close, minimize, and full-screen controls.

## Floating persona chat

- The hosted page detects the reply-capable `personastackChat` handler. Its existing Chat buttons open one ordinary native window per persona instead of the browser dock.
- Each window loads `/user/personas/chat/desktop-popout?persona_id=…` at the configured app origin. It shares the default WebKit data store. Native code never reads transcripts or calls chat APIs.
- The title bar and native buttons are hidden. Public AppKit transparency and a public layer mask expose transparent corners. The chat card remains readable. Collapsing resizes the same web view to a 72-point window containing a 64-point avatar.
- The hosted minus button miniaturizes to the Dock. Pin toggles `.normal` and `.floating` for that window. Avatar click collapses or expands. Avatar/header drag moves the window. Expansion preserves the expanded size at the avatar's current location and clamps to the screen.
- Web X and Cmd-W use the hosted API-backed close flow. Failed closes keep the chat visible. Navigation errors, denied loads, login/logout navigation, and changed hosted presentation scope dispose stale windows. Same-scope main-page navigation preserves them.
- Main bridge messages have version `1`, action `sync` with an opaque hosted storage `scope`, or `open_persona_chat` with that scope and `persona_id`. Scope is an in-memory invalidation key, never an authorization source.
- Popout bridge messages use version `1` and only `minimize`, `close`, `collapse`, `expand`, `pin`, or `drag` with finite bounded `dx`/`dy` numbers. Reject extra keys, unregistered web views, child frames, and origins other than the configured app origin.
- Window geometry, pinning, and the persona-window map are ephemeral. No launch restoration, all-Spaces mode, native message storage, new authentication flow, or independent stream is added.
- Run focused native checks with `swift test --disable-xctest`. Tests use Swift Testing and in-process AppKit windows without network loads.
- Explicit hosted/native acceptance uses the sibling web repository: build its TypeScript assets, then run `node scripts/desktop-chat-fixture.mjs`. Set `PERSONASTACK_CHAT_FIXTURE_URL` to its printed loopback URL and run `swift test --disable-xctest --filter HostedChatSmokeTests` in this repository. The fixture uses fake messages. This lane is skipped by ordinary tests and never contacts the PersonaStack API.

## Local persona sessions

- Only registered main application web views expose the reply-capable `personastackLocalSession` bridge. Validate exact configured origin, scheme, port, and main frame. Floating chats and OAuth popups cannot launch sessions.
- Version `1` messages are `state`, `select_harness`, `prepare`, and `configure`. Reject unknown fields. All messages carry the hosted presentation scope. Preparation checks the installed CLI before returning a native pending UUID. Pending IDs bind persona and harness for five minutes and are consumed once. Scope changes and login/logout invalidate pending work.
- Support only installed Codex CLI and Claude Code. Probe the user's login shell with bounded output and time. Require at least the inspected Codex 0.154.0 or Claude Code 2.1.152 baseline and required plugin-manager commands. Missing or unsupported CLIs require user installation or update. Never run an installer or obtain provider credentials.
- Keep one native harness preference per app origin. `select_harness` persists that preference without preparing or configuring a harness. Never persist bearer tokens or local-harness bundles in preferences. The hosted app remains responsible for the later authenticated configuration-preparation POST. The API owns each independent fixed 365-day credential and its ongoing authorization.
- Validate the typed local-harness bundle, fixed lifetime, endpoint allowlist, artifact digest, aggregate limits, and safe paths before local writes. Production bundles target `https://mcp.personastack.ai/v1/mcp`. Only the configured LAN app origin may use `http://mcp.personastack.lan/v1/mcp`.
- Private desktop plugin sources live under `~/Library/Application Support/PersonaStack/LocalHarnessPlugins/<harness>/<profile-hash>/<UUID>` with mode 0700. Files use 0600. An ownership manifest and source digest record the active source for that harness profile. Reconfiguration validates the recorded source, registered marketplace, installed plugin identity, and cache permissions before it removes only the recorded PersonaStack plugin and marketplace. Refuse symlink traversal, unmanaged collisions, and modified owned content.
- Each source is a local marketplace with one `personastack-local-<profile-hash>` plugin and `personastack-desktop-<profile-hash>` marketplace. Codex uses `.agents/plugins/marketplace.json`, `.codex-plugin/plugin.json`, and its `mcpServers` manifest shape. Claude Code uses `.claude-plugin/marketplace.json`, `.claude-plugin/plugin.json`, and its direct server-map manifest shape. Both receive a private authenticated MCP entry, the eager `PersonaStack` skill, and namespaced selected-skill snapshots that preserve relative assets and metadata. After installation Desktop makes the verified managed cache owner-only.
- Configuration runs only bounded selected-CLI plugin-manager commands with the existing profile directory. It never opens Terminal or starts an interactive CLI harness. It never edits `AGENTS.md`, `CLAUDE.md`, shell profiles, raw CLI configuration, or profile symlinks. Existing CLI auth, profiles, model settings, MCP servers, hooks, and plugins remain user-owned.
- This is not a sandbox. Downloaded private skills and persona instructions remain on the Mac. Existing CLI tools and plugins retain their user's trust. Fakes do not prove live CLI authentication or provider/MCP connectivity. Those require separately authorized smoke tests.

## Installer distribution

Each semantic version is an unsigned universal macOS disk image. A private GitHub release retains the immutable `PersonaStack-<version>-unsigned.dmg` installer. The release workflow copies the same DMG into a versioned public `personastack/homebrew-tap` Git tag and updates the `personastack` cask. Homebrew installs it with `brew install --cask personastack/tap/personastack`.
