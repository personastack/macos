# externalagentprotocol

`externalagentprotocol` owns the typed websocket contract between
`agent-gateway` and user-installed PersonaStack Connector processes.

The package is importable by the Connector repository. It defines endpoint
constants, finite enums, and concrete frame payload structs only. Gateway
runtime routing, Redis ownership, API callbacks, and Connector-local adapter
behavior live outside this package.

Managed external execution requires explicit `client_kind: macos_app` and scoped desktop preparation. Omitted or retired standalone client kinds grant no enrollment authority. `client_version` is informational app version metadata. Standalone distribution, install, updater and release fields and update frames are absent. Pairing protocol errors use `unsupported_protocol`. Protocol v4 remains the runtime target contract.
