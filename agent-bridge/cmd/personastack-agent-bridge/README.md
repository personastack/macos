# App background helper

Private signed app component. Starts one owner-private control socket, the existing outbound external-agent connection loops, and the bounded app-owned local cluster task owner. It has no public runtime command surface or root daemon. `--version` is the sole diagnostic argument. App version owns the embedded executable.

External-agent credentials and local VM control are independent. If the login Keychain is unavailable at startup, external operations fail with a finite credential error. Local status, Stop and Remove remain available. The external runner starts only with a verified installation seed. Restoring credential access requires a fresh helper login session. An unreadable local enable record keeps the control socket available instead of treating the VM as stopped.
