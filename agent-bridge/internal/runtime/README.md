# runtime

Native adapters implement authenticated full-control Hermes runs and OpenClaw operator gateway paths. Detection requires progress and stop support. Only assigned run events feed observation. No legacy response, CLI dispatch or transcript-observer fallback can become Ready.

OpenClaw static tools.catalog is used only for native capability descriptions. It cannot verify PersonaStack MCP. Cold native MCP verification refuses without dialing or submitting an agent run because the supported native effective inventory requires a persisted warm session. [The capability blocker](../../RUNTIME_SUPPORT.md#openclaw-cold-readiness-blocker) is separate from installed interoperability acceptance.

Hermes receives the API's composed prompt unchanged. The canonical API conversation ID and issued MCP namespace determine a bounded `X-Hermes-Session-Key`. The selected profile's native owner resolves that declared conversation across transcript compression. The request omits `session_id` so it cannot override the declared conversation. An assignment without a conversation retains the existing per-run `session_id` fallback. `Idempotency-Key` is the API assignment ID. Native continuation state never becomes PersonaStack's durable conversation or prompt authority.
