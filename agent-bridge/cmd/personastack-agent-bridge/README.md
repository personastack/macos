# App background helper

Private signed app component. No installer, updater, root daemon or public runtime command surface. Starts one owner-private control socket and the existing outbound gateway connection loops. `--version` is the sole diagnostic argument. App version owns the embedded executable.
