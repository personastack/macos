# PersonaStack for macOS

PersonaStack for macOS is the native desktop client for [my.personastack.ai](https://my.personastack.ai).

The app opens the existing hosted PersonaStack control panel in a dedicated macOS window. It keeps the website's authentication, sessions, OAuth callbacks, uploads, downloads, realtime updates, and product behavior intact. It does not duplicate product state or call PersonaStack internal services.

While the app is running, new concerns raise a native macOS notification. macOS asks for notification permission on first launch. The bridge sends no concern text, IDs, or account data to the app.

## Install

Install the current release with Homebrew:

```sh
brew install --cask personastack/tap/personastack
```

Homebrew downloads the matching `PersonaStack-<version>-unsigned.dmg`. You can also download the installer from the matching GitHub release. macOS will require a Gatekeeper override because the app is intentionally unsigned.

## Use

Open PersonaStack from Applications. Sign in at `my.personastack.ai` as usual. For a test target, launch it with `open -a PersonaStack --args --personastack-url https://personastack.ericgreer.info/`. The app stores website session data in its own persistent macOS WebKit data store.

User-selected external links open in the default browser. Existing top-level OAuth redirects remain in the app so the current `my.personastack.ai` callback flows continue to work.

The WebKit user agent includes `PersonaStackDesktop/1` so the shared web sidebar can omit its redundant logo header. This token is a presentation hint only. The environment badge appears beside the web app version in the sidebar footer.

## Requirements

- macOS 14 Sonoma or later
- Internet access to `my.personastack.ai` or LAN access to `personastack.ericgreer.info`

## Build an unsigned installer

```sh
./scripts/package-macos.sh
```

The installer appears in `artifacts/`. Set `VERSION=0.1.0` to choose its version.

## Test

```sh
swift run PersonaStackPolicyCheck
```

## Release

Tag a semantic version such as `v0.1.0`. The release workflow builds the unsigned disk image, attaches it to the private GitHub release, copies it to a versioned public Homebrew tap tag, and updates the cask. The repository needs a `HOMEBREW_TAP_TOKEN` secret with write access to `personastack/homebrew-tap`.

## Security boundary

The app is a presentation shell. `my.personastack.ai` remains the browser-facing authority. `personastack-api` remains the authority for identity, authorization, and product state. The app accepts one origin-checked native bridge event for generic concern notifications. It has no bundled credentials or direct access to PersonaStack APIs or datastores.
