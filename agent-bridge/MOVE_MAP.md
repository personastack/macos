# Moved source ownership

Connector remains intact during migration. The following packages and relevant tests move unchanged before focused repairs into this private module. All paths below retain their `internal/` prefix.

- Connector `internal/config` → macOS `agent-bridge/internal/config`.
- Connector `internal/daemon` → macOS `agent-bridge/internal/daemon`.
- Connector `internal/runtime` → macOS `agent-bridge/internal/runtime`.
- Connector `internal/targetinventory` → macOS `agent-bridge/internal/targetinventory`.
- Connector `internal/targetruntime` → macOS `agent-bridge/internal/targetruntime`.
- Connector `internal/mcp` → macOS `agent-bridge/internal/mcp`.
- Connector `internal/pairing` → macOS `agent-bridge/internal/pairing`.
- Connector `internal/buildinfo` → macOS `agent-bridge/internal/buildinfo`.
- Connector `internal/bridge` → macOS `agent-bridge/internal/bridge`.
- Connector `internal/diagnostics` → macOS `agent-bridge/internal/diagnostics`.
- Connector `internal/hermessetup` → macOS `agent-bridge/internal/hermessetup`.
- Connector `internal/openclawsetup` → macOS `agent-bridge/internal/openclawsetup`.
- Connector `internal/openclawauth` → macOS `agent-bridge/internal/openclawauth`.

Gateway `pkg/externalagentprotocol` replaces the duplicated Connector protocol package. No protocol DTO is copied. CLI, service, installmetadata, release-manifest and standalone release workflow packages are excluded. Legacy MCP proxies and root account switching are removed from the moved tree before task closure.

The new selected-profile, custody, ownership and migration contract has dedicated `TestDesktopAgentBridge*` in-process tests. Legacy CLI-release, root inventory, stdio/loopback proxy, uncancellable responses and transcript-observer tests were not moved because those modes are absent from the private helper. Retained bridge, runtime pure policy, auth-resolution and setup tests remain. The moved MCP HTTP probe keeps the initialize/initialized/tools-list parser and session negotiation. It has no stdio or GET notification proxy entrypoint.
