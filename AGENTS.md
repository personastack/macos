# macos-desktop instructions

- Keep hosted user, workspace, integration, persona, and billing state under `my.personastack.ai` and `personastack-api`. The native app may own a local Cua runtime, per-user machine credential in Keychain, local process/filesystem operations, and the authenticated machine connection to `agent-gateway`. It must not become a second human auth/API/product-state/datastore authority.
- Gate every machine command through the authenticated gateway contract and current API-projected persona/config/workspace scope. Never accept bearer credentials, machine IDs, arbitrary URLs, paths, commands, or raw frames from an untrusted WebView bridge as authorization.
- Cua and filesystem/process permissions are local OS capabilities. Report the responsible app identity and denied capability. Do not silently reset TCC, elevate commands, or log file/command content.
- Keep public web behavior owned by `my.personastack.ai`.
- Use semantic version tags for releases. The release workflow builds an unsigned DMG, attaches it to the private GitHub Release, copies the same immutable DMG to a versioned public `personastack/homebrew-tap` tag, and updates the tap cask. `HOMEBREW_TAP_TOKEN` needs write access to the tap.
- Do not commit credentials, signing certificates, notarization credentials, or local build artifacts.
