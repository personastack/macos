# PersonaStack for macOS specification

## Purpose

PersonaStack for macOS presents a selected PersonaStack web surface in a dedicated native macOS application window.

## Authority

- `my.personastack.ai` owns the hosted browser experience, cookies, public OAuth callbacks, and browser-facing composition.
- `personastack-api` owns identity, authorization, and product state.
- This client owns only the macOS application bundle, WebKit configuration, native window behavior, and installer packaging.

## Version 0.1.0 behavior

- Start at `/user/personas` on `https://my.personastack.ai` by default.
- Accept `--personastack-url <http-or-https-url>` at startup to override the initial URL for testing.
- Keep user-selected navigation on the override host in the app. Keep native bridge events restricted to approved PersonaStack hosts.
- Persist site data in the app's default WebKit data store.
- Keep Personastack-origin navigation in the app.
- Open user-selected external links and new windows in the default browser.
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

## Distribution

Each semantic version is an unsigned universal macOS disk image. A private GitHub release retains the immutable `PersonaStack-<version>-unsigned.dmg` installer. The release workflow copies the same DMG into a versioned public `personastack/homebrew-tap` Git tag and updates the `personastack` cask. Homebrew installs it with `brew install --cask personastack/tap/personastack`.
