# macos-desktop instructions

- Keep this client a thin presentation shell. Do not add a second PersonaStack API, authentication, authorization, product-state, or datastore path.
- Keep public web behavior owned by `my.personastack.ai`.
- Use semantic version tags for releases. The current release workflow builds an unsigned DMG and attaches it to the GitHub Release.
- Do not commit credentials, signing certificates, notarization credentials, or local build artifacts.
