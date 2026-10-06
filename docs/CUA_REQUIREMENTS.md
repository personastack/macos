# Standalone CUA requirements

PersonaStack uses official Cua Driver 0.29.1 as a separate application and login service. See [the native specification](../SPEC.md#desktop-control-relay) for the forwarding and lifecycle contract.

## Ownership

- Install the verified official app at `/Applications/CuaDriver.app`. The pinned permission-grant command requires this path.
- CUA owns its macOS permission identity, browser policy, direct-capture verification, service settings, and updates.
- PersonaStack's explicit local setup may install the app, establish its upstream login service, and invoke `permissions grant`.
- Passive connection checks cannot install, launch, restart, reconfigure, or request permission.
- A ready connection requires the signed live daemon, reviewed version/schema, standalone permission attribution, Accessibility and Screen Recording grants, and upstream direct-capture setup evidence. Action-specific refusals still come from CUA.
- Cloud agents cannot request permissions, install extensions, change CUA configuration, or choose another client's session.

## Independent lifetime

The CUA LaunchAgent and application live outside PersonaStack. PersonaStack quit, pause, disconnect, and uninstall end only PersonaStack access and its own CUA sessions. CUA and other clients remain independent. The PersonaStack relay must run for its cloud agents to reach CUA.

No PersonaStack filesystem/shell executor, browser permission adapter, locked-screen helper, or keep-awake subsystem participates in Desktop Control. Chat microphone and notifications remain independent app features.

## Versioned evidence

- [Pinned CLI source](https://github.com/trycua/cua/blob/cua-driver-rs-v0.29.1/libs/cua-driver/rust/crates/cua-driver/src/cli.rs): standalone setup commands and the MCP client no-autolaunch guard.
- [Pinned daemon source](https://github.com/trycua/cua/blob/cua-driver-rs-v0.29.1/libs/cua-driver/rust/crates/cua-driver/src/serve.rs): default local socket and daemon lifecycle.
- [Current operation guide](https://cua.ai/docs/cua-driver/guides/operate): upstream login-service configuration. Verify commands against the pin before adopting newer documentation.

A service status check is not proof of locked-screen, sleep, closed-lid, pre-login, or FileVault availability. Installed GUI and lifecycle acceptance must be recorded separately from source tests.
