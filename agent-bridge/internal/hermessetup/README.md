# hermessetup

Hermes uses one native shared gateway per OS user. Explicit native host consent may enable its default-home loopback API and start `hermes --profile default gateway run`. The command has no port argument. YAML and the native usable-key environment pass determine the effective port, host and default key. Setup preserves them. Explicit default selection defeats sticky named profiles and inherited selectors.

Named profiles keep their own MCP configuration and API key. They attach through `/p/<name>/` on the verified default host. Profile-only repair never grants host startup. Normal Check is read-only. A running ineligible or unproven native host remains unchanged and needs manual native setup. Disconnect never stops a shared gateway.

The literal config subset and configured/API/direct-MCP readiness boundary are documented in [RUNTIME_SUPPORT.md](../../RUNTIME_SUPPORT.md). Managed overlays, external secrets, root platform shorthand and unresolved values are unsupported. Native lock-directory resolution follows the launch home’s `.env` before inherited globals.
