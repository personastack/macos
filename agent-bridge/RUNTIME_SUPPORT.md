# Native runtime support

Evidence baseline: Connector source a669b296df23. Upstream source and documentation retrieved 2026-10-10. Hermes contract owner is NousResearch/hermes-agent `0d3b0348f5aab2bc263c81b660d761a76ded14fe` (pyproject version0.0.0). OpenClaw contract owner is openclaw/openclaw `8420f82cbbf8bd0114cacc39fa51299f92851a6f` (package version2026.9.9). A release number alone is not a capability proof. Each selected installed version must satisfy the full-control fixture below. Signed installed-app interoperability remains a separate acceptance gate.

| Runtime | Profile/config/state | Start/attach and endpoint proof | Authentication | Effective MCP | Assigned run lifecycle | Refusal |
| --- | --- | --- | --- | --- | --- | --- |
| Hermes | `HERMES_HOME` explicitly points at `~/.hermes` or `~/.hermes/profiles/<name>`; config.yaml, .env and state.db stay in that home. CLI `hermes -p <name> gateway` or equivalent explicit HERMES_HOME never uses sticky defaults. | Bind localhost using API_SERVER_HOST/PORT in that profile. Reuse only after exact current-user process/service profile arguments and port attribution, or native-reported identity, match canonical selected state/config. A responding port alone is refused. | Profile .env API_SERVER_KEY. No installation-global key fallback. | Selected profile tools registry must expose the API-issued server, API toolset must allow MCP; `no_mcp` is Needs setup. Direct PersonaStack tools/list alone is insufficient. | Authenticated `/v1/capabilities` requires run_submission, run_status, run_events_sse, run_stop; POST `/v1/runs`, SSE `/v1/runs/{id}/events`, GET run fallback, POST stop. Requests preserve composed input/session/conversation and declared namespace. | Missing capability → runtime_unsupported. Wrong/unproven owner or occupied port → runtime_conflict. Missing/denied profile credentials → credential_unavailable. Legacy responses cannot be Ready. |
| OpenClaw | Default `~/.openclaw`; named `~/.openclaw-<name>`. Explicit `--profile <name>` plus OPENCLAW_STATE_DIR and OPENCLAW_CONFIG_PATH. Agent IDs share that profile and do not create independent persona targets. | Selected operator gateway `gateway run --port <port>` with exact named profile/config/state. Port reuse requires current-user process/service attribution or native profile identity. Never attach merely because health responds. | Selected openclaw.json gateway operator credential/device material. Process global home/token never selects another profile. | Unsupported cold verification. `tools.catalog` is static core/plugin inventory. `tools.effective` requires a persisted session with an already-warm native MCP catalog. Neither direct MCP reachability nor a matching plugin proves native readiness. | Operator protocol 3/4 auth/challenge. `agent` RPC message + assignment idempotencyKey + selected agentId; exact run-correlated events and `agent.wait`; `sessions.abort` for assigned native run. | Auth mismatch → credential_unavailable. Missing gateway operations/native catalog → runtime_unsupported. CLI fallback cannot be Ready. Foreign run/agent/session event ignored. |

## OpenClaw dispatch agent

Native discovery reads configured `agents.entries` or the supported `agents.list` shape from the selected profile. A sole agent is selected automatically. Several agents require the native picker. A config with neither roster property exposes the pinned upstream implicit `main` agent. Explicit empty, invalid or ambiguous rosters never fall back to `main`. The selected opaque candidate binds the physical profile and config snapshot. Preparation and enrollment reject stale choices before exchange or persistence. The helper stores the exact selected agent and validates its presence before configuration, effective catalog checks and dispatch. The API continues to select the physical profile. Agents do not create separate persona targets. [OpenClaw agent configuration](https://docs.openclaw.ai/gateway/config-agents)

## Fixture contract

| Input | Expected |
| --- | --- |
| Two Hermes canonical homes plus one named OpenClaw state/config | Three isolated profiles/endpoints and credentials. |
| Symlink alias or hardlinked config of an enrolled profile | Same physical target; second persona returns profile_in_use. |
| Shared OpenClaw profile with different agent ID | Same profile target; no independent enrollment. |
| Sole non-main OpenClaw agent | Native auto choice, persisted exact agent and dispatch agentId. |
| Several configured OpenClaw agents | Native explicit picker; cancel has zero reservation/config writes. |
| Changed config or document after choosing OpenClaw agent | scope_changed before pairing exchange or persistence. |
| Same API connection ID in two approved server origins | Independent local state/secret keys. |
| Hermes capability response lacks progress or stop | runtime_unsupported; no start submission. |
| OpenClaw cold setup with direct tools/list success | Not Ready. No model run or guessed discovery RPC. |
| Native event has foreign run or target identity | Zero assigned-run observation/output mutation. |
| Local port is occupied without selected-profile ownership evidence | runtime_conflict; no attach/restart. |
| Keychain refuses selected credential | credential_unavailable; no fallback secret file. |

Primary references: [Hermes API](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server), [Hermes profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles), [OpenClaw CLI](https://docs.openclaw.ai/cli), [OpenClaw MCP](https://docs.openclaw.ai/tools/mcp), [OpenClaw gateway](https://docs.openclaw.ai/gateway/protocol).

## Pinned source evidence

Read directly from the identified immutable Git revisions. These are source contract evidence. No installed-runtime or signed-app interoperability is claimed.

| Source | Evidence used |
| --- | --- |
| [Hermes api_server.py at0d3b0348](https://github.com/NousResearch/hermes-agent/blob/0d3b0348f5aab2bc263c81b660d761a76ded14fe/gateway/platforms/api_server.py) | capabilities features include run_submission, run_status, run_events_sse, run_stop. API_SERVER_HOST/PORT is selected profile environment. |
| [Hermes api_server_runs.py at0d3b0348](https://github.com/NousResearch/hermes-agent/blob/0d3b0348f5aab2bc263c81b660d761a76ded14fe/gateway/platforms/api_server_runs.py) | registered POST run, GET status, GET events, POST stop. Events carry run_id. |
| [OpenClaw agent handler at8420f82c](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/gateway/server-methods/agent-run-handler.ts), [agent wait](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/gateway/server-methods/agent.ts) | validated agent request submission and run-correlated agent.wait. |
| [OpenClaw sessions schema at8420f82c](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/packages/gateway-protocol/src/schema/sessions.ts) | SessionsAbortParamsSchema accepts exact runId. |
| [OpenClaw tools catalog at8420f82c](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/gateway/server-methods/tools-catalog.ts) | tools.catalog resolves selected agentId but returns static core/plugin tools. It does not establish effective MCP readiness. |

Local production probes read only selected native profile configuration. Existing declared native ports are reused after independent process ownership checks. Profiles declaring the same occupied port produce runtime_conflict. The desktop never stops a foreign listener. No live native runtime was started during source regression checks.

Native config parsing currently supports strict JSON only. Pinned upstream OpenClaw also supports JSON5 through its config reader. JSON5, malformed or oversized configs produce `native_config_unsupported` and remain unchanged. This helper does not normalize or rewrite them automatically. Agent rosters are bounded to 128 entries per profile. Labels are bounded to 256 UTF-8 bytes and include the agent ID when a display name differs. The native inventory is bounded to 128 profiles and 256 agent candidates in total.

Pinned default authority: [agent-roster.ts at8420f82c](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/agents/agent-roster.ts) exposes the legacy implicit agent only without a roster property. [session-key.ts](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/routing/session-key.ts) identifies it as `main`. [Config reader facade](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/config/io.ts) exposes JSON5 parsing. These are source compatibility limits, not installed-runtime evidence.

## OpenClaw cold readiness blocker

The pinned gateway does not expose a general cold, no-model session MCP discovery operation. `tools.effective` reads the chosen session's existing native catalog. It refuses unknown sessions and returns a notice when the catalog is cold, missing or stale. Its MCP entries use `source: "mcp"`, `pluginId: "bundle-mcp"`, `mcpServer`, `mcpToolName` and optional `deniedBySession`. Matching a static plugin ID cannot establish that evidence. The helper fails verification explicitly and never reports OpenClaw Ready on this baseline. Hermes remains independently supported.

Evidence: [pinned tools.effective](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/gateway/server-methods/tools-effective.ts#L329-L356), [MCP inventory projection](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/agents/tools-effective-mcp-inventory.ts#L25-L45) and [pinned public schemas](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/packages/gateway-protocol/src/schema/tools-catalog.ts). Current official source `004715e781ed7776e9d5063607220b34b91b23e0`, read 2026-10-10, retains the [warm-only rule](https://github.com/openclaw/openclaw/blob/004715e781ed7776e9d5063607220b34b91b23e0/src/gateway/server-methods/tools-effective.ts). `tools.invoke` uses a separate Gateway core/plugin surface. CLI `mcp probe` and `doctor --probe` prove transport reachability rather than effective session policy.

The separate native `mcp.app.discover` operation can materialize an authorized session runtime only when MCP Apps are explicitly enabled. [Its owner](https://github.com/openclaw/openclaw/blob/004715e781ed7776e9d5063607220b34b91b23e0/src/gateway/mcp-app-extension-runtime.ts#L64) requires this opt-in and session authority. The helper does not enable that product surface or create a session as a readiness workaround. Supported options require a product decision: add an upstream supported no-model discovery operation, deliberately support the MCP Apps/session setup path, or defer OpenClaw Ready. Installed interoperability cannot resolve this missing source capability by itself.
