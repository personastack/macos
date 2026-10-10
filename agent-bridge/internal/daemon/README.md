# daemon

The app-owned user helper supervises keyed outbound gateway sessions. The API owns target selection, assignments and connection authority. Each selected profile has its own native adapter and endpoint. Native callbacks are fenced by connection generation and assigned run. Readiness and assigned run state feed native control status. Quiescing blocks new runs while accepted work remains observed.
