# openclawauth

Resolve credentials from the explicitly selected OpenClaw state/config. Daemon calls supply an empty global token environment and the exact config path. The helper never selects a different profile because its process environment contains a token.
