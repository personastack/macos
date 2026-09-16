# macos-desktop instructions

- Keep this client a thin presentation shell. Do not add a second PersonaStack API, authentication, authorization, product-state, or datastore path.
- Keep public web behavior owned by `my.personastack.ai`.
- Use semantic version tags for releases. The release workflow builds an unsigned DMG, attaches it to the private GitHub Release, copies the same immutable DMG to a versioned public `personastack/homebrew-tap` tag, and updates the tap cask. `HOMEBREW_TAP_TOKEN` needs write access to the tap.
- Do not commit credentials, signing certificates, notarization credentials, or local build artifacts.
