# mcp

The helper writes direct authenticated HTTP entries into the selected native profile. It updates or removes only the exact unchanged entry recorded by an HMAC ownership record. Native effective tool catalog verification precedes the direct initialize/initialized/tools-list probe. Migration captures an exact old entry and private native config backup before replacing it with newly issued API credentials. There is no stdio or loopback MCP proxy entrypoint.

## Explicit Hermes Repair

Native consent allows the selected profile's `platform_toolsets.api_server` list to remove `no_mcp` and include the API-issued PersonaStack server. Other platforms and toolsets stay unchanged. Ordinary MCP installation does not change toolset policy. Effective native catalog verification and the direct MCP handshake must still pass before readiness becomes verified.

The [pinned Hermes resolver](https://github.com/NousResearch/hermes-agent/blob/0d3b0348f5aab2bc263c81b660d761a76ded14fe/hermes_cli/tools_config.py) uses `mcp_servers` keys as platform allowlist names. Repair accepts a YAML list or a string containing a list. Invalid shapes return `cleanup_required` instead of replacing the user's selection. Tests mock native catalog results. They do not prove installed Hermes interoperability.

## Explicit OpenClaw Apps Repair

Native Apps consent is separate from gateway start or restart consent. Private Repair pins positive connection generation and target-selection revision. It enables only the selected strict-JSON profile's `mcp.apps.enabled` value inside the existing admission/configuration guard. Other keys and user sandbox settings remain unchanged. Upstream default or explicit loopback bind is required. Lan, custom, auto and malformed shapes fail before any write. A running gateway also requires actual numeric loopback-only listener evidence on the attributed profile PID. Helper startup passes explicit `--bind loopback`. The flag remains enabled after disconnect.

Apps permits HTML Apps and an additional sandbox listener on the same Gateway bind hosts. Normal installation and Check cannot enable it. Consented setup creates an empty helper-owned selected-agent session and uses supported Apps discovery before effective tool verification. Ordinary Check reads that retained session. The direct MCP handshake follows native verification and cannot substitute for it. See [runtime support](../../RUNTIME_SUPPORT.md#openclaw-mcp-apps-and-no-model-readiness) for pinned producer evidence and remaining installed-app acceptance.
