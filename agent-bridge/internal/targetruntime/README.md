# targetruntime

Resolve loopback endpoints from the selected native config. Prove listener UID and exact runtime/config/state attribution before attachment. Ports with foreign or ambiguous ownership return runtime_conflict. Pure endpoint and process-evidence fixtures cover attribution without spawning native services.

Pinned OpenClaw sets the macOS gateway process title to exactly `openclaw-gateway` ([run-loop.ts](https://github.com/openclaw/openclaw/blob/8420f82cbbf8bd0114cacc39fa51299f92851a6f/src/cli/gateway-cli/run-loop.ts#L71-L75)). That title identifies the runtime but never authorizes attachment. After `lsof` selects one listener PID and `ps` proves the current UID, Darwin `KERN_PROCARGS2` supplies that PID's original environment. The bounded parser separates argv from environment and returns only exact `OPENCLAW_STATE_DIR` and `OPENCLAW_CONFIG_PATH` fields. Missing, foreign, duplicate or inaccessible fields fail closed. Raw argv/environment is neither logged nor persisted.

An actual bounded macOS Node title-mutation check confirmed that `ps eww` drops environment output while `KERN_PROCARGS2` retains both dummy profile fields. Source fixtures pin that producer shape and wrong UID/root/config denial. A Darwin-only in-process test reads its own test PID to cover the native syscall boundary. These checks do not prove installed OpenClaw runtime readiness.
