# PersonaStack for macOS

PersonaStack for macOS is the native desktop client for [my.personastack.ai](https://my.personastack.ai).

The app opens the existing hosted PersonaStack control panel in a dedicated macOS window. It keeps the website's authentication, sessions, OAuth callbacks, uploads, downloads, realtime updates, and product behavior intact. It does not duplicate product state or call PersonaStack internal services.

While the app is running, new concerns raise a native macOS notification. macOS asks for notification permission on first launch. The bridge sends no concern text, IDs, or account data to the app.

## Install

Download `PersonaStack-<version>-unsigned.dmg` from the matching GitHub release. Open the disk image. Drag `PersonaStack.app` into Applications. macOS will require a Gatekeeper override because the first release is intentionally unsigned.

## Use

Open PersonaStack from Applications. Sign in at `my.personastack.ai` as usual. The app stores website session data in its own persistent macOS WebKit data store.

User-selected external links open in the default browser. Existing top-level OAuth redirects remain in the app so the current `my.personastack.ai` callback flows continue to work.

## Requirements

- macOS 14 Sonoma or later
- Internet access to `my.personastack.ai`

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

Tag a semantic version such as `v0.1.0`. The release workflow builds an unsigned disk image and attaches it to the GitHub release.

## Security boundary

The app is a presentation shell. `my.personastack.ai` remains the browser-facing authority. `personastack-api` remains the authority for identity, authorization, and product state. The app accepts one origin-checked native bridge event for generic concern notifications. It has no bundled credentials or direct access to PersonaStack APIs or datastores.
