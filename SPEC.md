# PersonaStack for macOS specification

## Purpose

PersonaStack for macOS presents `https://my.personastack.ai` in a dedicated native macOS application window.

## Authority

- `my.personastack.ai` owns the hosted browser experience, cookies, public OAuth callbacks, and browser-facing composition.
- `personastack-api` owns identity, authorization, and product state.
- This client owns only the macOS application bundle, WebKit configuration, native window behavior, and installer packaging.

## Version 0.1.0 behavior

- Start at `/user/personas` on `my.personastack.ai`.
- Persist site data in the app's default WebKit data store.
- Keep Personastack-origin navigation in the app.
- Open user-selected external links and new windows in the default browser.
- Allow automated top-level redirects to preserve existing OAuth callback flows.
- Download non-displayable responses to the user's Downloads directory.
- Expose no native JavaScript bridge, local API, credentials, or direct PersonaStack service connection.

## Distribution

Version 0.1.0 is an unsigned universal macOS disk image. A GitHub release publishes the immutable `PersonaStack-<version>-unsigned.dmg` installer for each `v*` tag.
