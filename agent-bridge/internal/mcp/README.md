# mcp

The helper writes direct authenticated HTTP entries into the selected native profile. It updates or removes only the exact unchanged entry recorded by an HMAC ownership record. Native effective tool catalog verification precedes the direct initialize/initialized/tools-list probe. Migration captures an exact old entry and private native config backup before replacing it with newly issued API credentials. There is no stdio or loopback MCP proxy entrypoint.

## Explicit Hermes Repair

Native consent allows the selected profile's `platform_toolsets.api_server` list to remove `no_mcp` and include the API-issued PersonaStack server. Other platforms and toolsets stay unchanged. Ordinary MCP installation does not change toolset policy. Effective native catalog verification and the direct MCP handshake must still pass before readiness becomes verified.

The [pinned Hermes resolver](https://github.com/NousResearch/hermes-agent/blob/0d3b0348f5aab2bc263c81b660d761a76ded14fe/hermes_cli/tools_config.py) uses `mcp_servers` keys as platform allowlist names. Repair accepts a YAML list or a string containing a list. Invalid shapes return `cleanup_required` instead of replacing the user's selection. Tests mock native catalog results. They do not prove installed Hermes interoperability.
