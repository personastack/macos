# macOS client environment reference

This repository owns the Swift native client, its local Go agent bridge, native harness setup and macOS packaging. It is not a LAN or Railway backend service. Application environments are selected through approved native configuration, the packaged `PersonaStackDefaultURL` Info.plist key and `--personastack-url`. `PERSONASTACK_DEFAULT_URL` is a packaging input, not a Swift launch-time environment reader. Native machine and harness credentials remain in their existing private file/Keychain custody. Server 1Password Environments are not client credential stores.

## Native account and subprocess inputs

All rows here apply to the logged-in macOS client account in the selected environment. They are non-secret settings or local path/session metadata. These existing account and harness inputs are not Kubernetes deployment bindings. Managed local Kubernetes uses the private native settings and fixed child projection below.

| Name | Consumer / purpose | Requiredness and unset behavior |
| --- | --- | --- |
| `HOME`, `PATH` | `Sources/PersonaStackCore/LocalSessionProbe.swift`: login-shell harness discovery. Go Hermes/OpenClaw discovery also uses account home and executable search. | Expected session inputs. Probe must resolve a valid executable, home and profile. Go OpenClaw resolver can fall back to OS home. Selected native account replaces child `HOME`; selected launch context replaces relevant `PATH`. |
| `CODEX_HOME` | Local Session Codex profile. | Optional. Login-shell probe defaults to `$HOME/.codex`; selected profile replaces child value. |
| `CLAUDE_CONFIG_DIR` | Local Session Claude profile. | Optional. Login-shell probe defaults to `$HOME/.claude`; selected profile replaces child value. |
| `USER`, `LOGNAME` | `DesktopShellExecutor.swift` and native harness launchers: child account identity. `runtime/hermes.go` also uses `USER` for known Nix installation candidates. | Expected OS account inputs. Explicit native process identity overrides child values. Unset discovery omits the user-specific candidate. |
| `SHELL` | Native shell child environment. | Child receives selected account shell. Local Session selects login shell through the account record, not an arbitrary `SHELL` override. |
| `TERM` | `DesktopShellExecutor.swift`: PTY terminal description. | Optional. PTY mode defaults to `xterm-256color`; pipe mode does not synthesize it. |
| `TMPDIR`, `LANG`, `LC_ALL`, `LC_CTYPE` | Cua subprocess allowlist in `CuaDriverCompatibility.swift`; shell/script temporary and locale context. | Optional inherited values. Missing keys are omitted by Cua projection. Packaging shell helpers use `/tmp` when `TMPDIR` is unset. |
| `CUA_DRIVER_RS_TELEMETRY_ENABLED`, `CUA_DRIVER_RS_UPDATE_CHECK` | Cua installer/proxy child outputs. | Always forced to disabled telemetry and update checking. Parent values cannot override the managed projection. |

Cua inherits only `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_ALL`, `LC_CTYPE` plus its two managed outputs. Desktop shell and Local Session harness commands intentionally inherit the account/login-shell environment. Arbitrary user or provider settings inherited there belong to the chosen shell/harness. They are not new PersonaStack settings. The hook uses explicit command arguments rather than an environment credential contract.

## Agent bridge and native harness compatibility

Sources are under `agent-bridge/internal/{runtime,hermessetup,openclawsetup,openclawauth,targetruntime,daemon}`. These are local native-harness inputs, not cloud service secrets.

| Name | Purpose and binding | Requiredness and unset behavior | Secret |
| --- | --- | --- | --- |
| `PERSONASTACK_CONNECTOR_HERMES_URL` | Generic compatibility `runtime.NewAdapter` Hermes endpoint. | Optional. Adapter defaults to local Hermes API. Target-scoped daemon flow resolves selected native config instead. | No |
| `PERSONASTACK_CONNECTOR_OPENCLAW_GATEWAY_URL` | Generic compatibility adapter endpoint. | Optional. Defaults to `ws://127.0.0.1:18789`. Target-scoped daemon flow resolves selected native config instead. | No |
| `OPENCLAW_AGENT_ID` | Generic compatibility adapter agent selection. | Optional. Empty retains adapter's default-agent handling. | No |
| `PERSONASTACK_CONNECTOR_DISABLE_HERMES_GATEWAY_START`, `PERSONASTACK_CONNECTOR_DISABLE_OPENCLAW_GATEWAY_START` | Explicit local harness startup controls. | Optional. Exact `1` skips the corresponding launch. Unset allows ordinary guarded startup. | No |
| `HERMES_BIN` | Hermes executable override. | Optional. Must be executable when set. Otherwise PATH and known install locations are searched. | No |
| `HERMES_HOME` | Hermes profile root through `hermessetup.ResolvePaths`. | Optional. Explicit selected root wins, then this variable, then `<account-home>/.hermes`. Selected child receives the resolved root. | No |
| `HERMES_MANAGED_DIR` | Hermes supported native managed-directory policy. | Optional. Selected profile `.env` can override inherited value. Unsupported placement fails closed. | No |
| `XDG_STATE_HOME`, `HERMES_GATEWAY_LOCK_DIR` | Hermes native lock rendezvous. | Optional. Profile `.env` overrides inherited values. Explicit lock directory must be a literal absolute path. Otherwise use `<XDG_STATE_HOME>/hermes/gateway-locks`, falling back to `<home>/.local/state/hermes/gateway-locks`. | No |
| `API_SERVER_ENABLED` | Hermes native `.env` setup output. | Explicit setup writes `true`. Native API enablement remains producer-owned. Not inherited from bridge globals. | No |
| `API_SERVER_HOST`, `API_SERVER_PORT` | Hermes native `.env` API bind overrides. | YAML/native defaults are loopback and port8642. Usable `.env` key enables nonempty host/port overrides. Unsupported/nonloopback binds are rejected. | No |
| `API_SERVER_KEY` | Hermes native `.env` API credential. | Existing usable key retained. Explicit setup creates one when needed. Missing usable credential leaves adapter unavailable. Never document its value. | Yes |
| `HERMES_PROFILE`, `HERMES_PROFILE_NAME` | Inherited profile selectors removed before shared-host launch. | Never use ambient values to select a different gateway. Launch explicitly chooses the native default host. | No |
| `PREFIX`, `LOCALAPPDATA` | Generic Hermes known-install candidate discovery. | Optional. Unset omits those candidate directories. `LOCALAPPDATA` is a cross-platform compatibility path rather than macOS deployment config. | No |
| `OPENCLAW_STATE_DIR`, `OPENCLAW_HOME`, `OPENCLAW_CONFIG_PATH` | OpenClaw resolver and native process identity capture. | Explicit selected state root/config wins. Generic resolver then uses state override, home override plus `.openclaw`, or account-home `.openclaw`; config defaults to that state's `openclaw.json`. Target process capture must prove exact selected identity. | No |
| `OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_GATEWAY_PASSWORD`, `OPENCLAW_GATEWAY_DEVICE_TOKEN` | Generic OpenClaw credential resolver. Also recognized in selected config/env/service sources. | Optional resolver candidates. Binding/explicit credentials precede generic process environment. **Target-scoped daemon passes empty global credential values** and reads the selected profile authority instead. Missing usable auth leaves target unavailable. | Yes |
| `BASH_ENV`, `ENV`, `NODE_OPTIONS`, `NODE_PATH` | OpenClaw launch environment filtering. | Removed for selected native launch with all ambient `OPENCLAW_*` keys before exact selected bindings are installed. Not accepted app configuration. | Potentially sensitive inherited inputs |

Dynamic families: native Hermes launch removes ambient `API_SERVER_*`, `HERMES_PROFILE` and `HERMES_PROFILE_NAME`. OpenClaw selected launch removes all `OPENCLAW_*` globals before assigning exact state/config. `PERSONASTACK_CONNECTOR_LOCAL_MCP_*` is a diagnostic redaction pattern, not a dynamic environment reader. The message `HERMES_API_SERVER_KEY is required` is diagnostic text; no reader for that variable exists. The native credential file key is `API_SERVER_KEY`.

## Managed local runtime settings and custody

Managed Kubernetes adds no operator-provided environment credential, URL, command or kubeconfig input. The native helper owns one private runtime directory. Its `owner.json` records the retained App origin, account, workspace, bootstrapped state and local enabled intent. That local custody is separate from Hermes/OpenClaw bindings and Keychain entries. Cloud integration identity, credential issuance, assignment and worker storage remain API-owned. Native enrollment responses and guest Secret material never enter page messages or UserDefaults.

Lima child commands receive fixed app-owned `HOME`, `LIMA_HOME` and `TMPDIR` directories. They receive `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `LANG=C` and `LC_ALL=C`. Ambient host credentials, the user's `~/.lima` and the user's `~/.kube` are not runtime inputs. Artifact paths, versions and resource limits come from native-owned descriptors. Page messages cannot override them.

| Native setting | Owner and meaning | Absent behavior |
| --- | --- | --- |
| `agentBridge.backgroundDisabled` | UserDefaults mirror of explicit Hermes/OpenClaw background disable intent. It does not disable the local cluster. Helper startup uses its private shared disabled marker and actual cluster custody. Explicit native setup can clear that startup marker while retaining external disable intent and quiesced bindings. | No explicit external disable preference. |
| `agentBridge.backgroundError` | Bounded native helper-registration or restore feedback. It carries no owner names, credentials or raw child output. | No saved feedback. |
| `agentBridge.restoreAfterAppUpdate` | Existing native update handoff requests registration restore after replacement. A cluster-only restore preserves external disable intent and quiesced bindings. It may clear the shared startup disabled marker to launch the helper. | No replacement restore requested. |
| `agentBridge.restoreLocalRuntimeAfterAppUpdate` | Native handoff captures the prior cluster enable intent before the first explicit Stop and update. Stop may save disabled intent before proving exit. Retries retain the original choice. The key is cleared only after successful restoration or cancellation. It grants no cloud scope or enrollment authority. | No cluster resume requested. |

The existing helper `status` response advertises optional `local_cluster_control_version: 1`. Native code checks that typed capability before new runtime operations. Absence is the explicit compatibility case for the published pre-feature helper. Present malformed or unknown versions fail closed. Capability and runtime-query errors do not prove that a VM is absent. A typed `external_error` reports unavailable external Keychain custody without projecting an empty connection inventory. External operations retain their credential failure. The narrow local capability read ignores that independent inventory error so local Stop and Remove still work. Helper retirement remains blocked while external status is unknown. Startup installation-credential failure remains fixed for the helper lifetime. Restore login Keychain access and sign out of macOS, then sign back in to restart it. PersonaStack app sign-out does not restart the helper.

Generic same-user runtime status contains local installed/running/Kubernetes availability, enabled intent, active-operation state and a finite safe reason. It contains no account, workspace, persona, path or credential metadata. False running alone cannot prove stopped when an operation or failed observation remains. The informational `local_data_removed` reason permits replacement only when installed, running, Kubernetes availability, enabled intent and active-operation state are all false. Stop, Resume and Remove Local Data use finite helper operations with bounded native polling. Menu removal requires native destructive confirmation. The runtime's single removal task owns initial Stop and stopped-process proof. Native code sends no separate Stop before removal or a partially erased retry. It reports local removal only after the exact removed-data status. It performs no cloud mutation or installation-key rotation. Timeout leaves status unknown until checked again. These settings do not add an installer journal or an exactly-once guarantee.

The existing uninstall argument `--personastack-unregister-login` now awaits owned VM and runtime-payload removal before unregistering login services. It uses the app instance lock to exclude a running GUI. Native menu removal and uninstall share the no-enable eraser. The fixed signed helper invocation `--remove-local-runtime` is the offline fallback. It accepts no path, scope, environment credential or custom command arguments. The normal helper and one-shot remover hold `AgentBridge/local-runtime-owner.lock` for their lifetime. The private regular single-link lock file is never unlinked. Its inode cannot split between owners. Runtime payload erasure leaves minimal ownership/removal custody and unrelated entries. No new environment variable is introduced.

Removal uses a 60-second native wait. Stop and Resume keep their existing 40-second waits. A native timeout does not authorize app deletion or service unregistration. Direct Finder deletion bypasses this command. Use verified local removal before manually deleting the app.

## Packaging and signing inputs

These variables apply only to developer/CI packaging, signing, notarization and distribution. They are not application runtime settings and do not belong in LAN Kubernetes projections. Credential values remain in approved protected release stores and ephemeral runner files. “Required” means required for the named operation, not for ordinary app launch.

| Name | Consumer / purpose | Requiredness and unset behavior | Secret |
| --- | --- | --- | --- |
| `VERSION`, `CONFIGURATION`, `CLEAN_BUILD` | `scripts/package-macos.sh`: version, Swift build mode, clean scratch directories. | Optional. Defaults `0.1.0`, `release`, `1`. Configuration accepts debug/release; stable numeric version required. Only exact clean value `1` removes build scratch. | No |
| `PERSONASTACK_DEFAULT_URL` | Package's `PersonaStackDefaultURL` Info.plist. | Required for packaging. | No |
| `PERSONASTACK_SPARKLE_PUBLIC_ED_KEY` | Packaged `SUPublicEDKey`. | Optional for standalone script; when supplied must decode to a32-byte public key. Release workflow requires matching configured public/private pair. | No |
| `PERSONASTACK_CODESIGN_IDENTITY`, `PERSONASTACK_CODESIGN_KEYCHAIN` | `sign-app.sh`, package and signing-continuity helper. | Required for signed packaging. Import helper exports certificate-backed identity and ephemeral keychain path. Ad-hoc identity rejected. | No, but keychain contains protected material |
| `PERSONASTACK_INSTALLER_SIGNING_IDENTITY` | Main installer signing. | Required for release package or signed installer helper. Import helper derives it. | No |
| `PERSONASTACK_SIGN_INSTALLER` | `package-desktop-installer.sh` signing switch. | Optional. Defaults `1`; main packaging forces `1`. | No |
| `PERSONASTACK_CODESIGN_CERTIFICATE_P12_BASE64`, `PERSONASTACK_CODESIGN_CERTIFICATE_PASSWORD` | `import-release-signing.sh` application identity archive/password. | Both required for import. Workflow maps `PERSONASTACK_DEVELOPER_ID_P12_BASE64` and `PERSONASTACK_DEVELOPER_ID_PASSWORD` secret names to these process names. | Yes |
| `PERSONASTACK_INSTALLER_CERTIFICATE_P12_BASE64`, `PERSONASTACK_INSTALLER_CERTIFICATE_PASSWORD` | Installer identity archive/password. | Both required for import. Workflow maps `PERSONASTACK_DEVELOPER_ID_INSTALLER_P12_BASE64` and `PERSONASTACK_DEVELOPER_ID_INSTALLER_PASSWORD`. | Yes |
| `PERSONASTACK_COMMUNICATION_PROFILE_BASE64` | `communication_profile.py` materializes Apple entitlement profile. | Required for the workflow materialization step. Produces a protected runner file. | Sensitive signing artifact |
| `PERSONASTACK_COMMUNICATION_PROFILE` | Signing's existing entitlement profile path. | Required for profile validation/signing. Workflow materialization exports it. | Path is not secret; referenced signing artifact is sensitive |
| `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | Workflow's notarization preflight. | Required. Maps `PERSONASTACK_NOTARY_KEY_P8_BASE64`, `PERSONASTACK_NOTARY_KEY_ID`, `PERSONASTACK_NOTARY_ISSUER_ID`; decodes key into runner file. | Key yes; identifiers no |
| `PERSONASTACK_NOTARY_KEY_PATH`, `PERSONASTACK_NOTARY_KEY_ID`, `PERSONASTACK_NOTARY_ISSUER_ID` | `scripts/notarize.sh` API authentication. | Required. Workflow exports them after preflight. | Path/identifiers no; referenced private key yes |
| `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY` | Workflow pair validation and `publish-homebrew-release.sh` / `verify-published-release.py`. | Release workflow requires both. Private key required for appcast signing and published-archive verification. Mapped from public variable `PERSONASTACK_SPARKLE_PUBLIC_ED_KEY` and secret `PERSONASTACK_SPARKLE_PRIVATE_ED_KEY`. | Private key yes; public key no |
| `HOMEBREW_TAP_TOKEN`, `GH_TOKEN` | Workflow tap access and source/tap publication scripts. | Required for relevant authenticated publish. Workflow maps ordinary source publication to its GitHub token and tap publication to `HOMEBREW_TAP_TOKEN`. No token values in source. | Yes |
| `REQUESTED_VERSION`, `RELEASE_VERSION`, `RELEASE_DATE` | Workflow release selection and downstream notes/package steps. | Workflow-provided input/output. Missing/invalid version fails selection. Date generated once and reused. | No |
| `CANDIDATE_ARTIFACT_ID`, `CANDIDATE_ARCHIVE_DIGEST`, `CANDIDATE_SHA256`, `EXPECTED_SHA256` | Workflow's immutable candidate receipt and verify input. | Generated from candidate upload/sealing. Required for those receipt/verification operations. No user runtime default. | No |
| `RUNNER_TEMP`, `GITHUB_ENV` | Signing/profile import and workflow exports. | Required runner paths for these helpers. No project fallback. | No; files may hold protected material |
| `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`, `GITHUB_WORKSPACE`, `GITHUB_SHA`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT` | Workflow outputs, summary, source identity, artifact paths and run identity. | GitHub-provided platform inputs. No application default. | No |
| `GOFLAGS`, `GOPROXY`, `GOSUMDB`, `GOOS`, `GOARCH`, `CGO_ENABLED`, `CC`, `CGO_CFLAGS`, `CGO_LDFLAGS` | `build-agent-bridge.sh`: reproducible vendored ARM64-only bridge build. | Script assigns vendoring, disabled remote lookup, Darwin ARM64 target, ARM64 C toolchain and SDK flags. CI test step sets vendored/offline module flags too. Not operator runtime inputs. | No |

Shell script scratch names such as `PWD` capture, `root_dir` and generated release hashes are not independent configuration inputs. Standard Swift, Go, Apple and GitHub tool settings not explicitly owned above remain tool-owned.

## Tests and fixture-only controls

| Names | Consumer / purpose | Requiredness and unset behavior | Secret / environment |
| --- | --- | --- | --- |
| `PERSONASTACK_CHAT_FIXTURE_URL`, `PERSONASTACK_STREAM_DOWNLOAD_FIXTURE_URL` | Hosted Swift smoke fixtures. | Optional. Corresponding test is disabled when absent. Explicit live fixture setup is separate authorization. | No credentials in URL. Test only. |
| `PERSONASTACK_NATIVE_RENDER_DIR` | `DesktopDiagnosticsRenderingTests.swift`: optional render artifact destination. | Optional. No external artifact write when unset. | No. Test only. |
| `PERSONASTACK_NATIVE_LIFECYCLE_ACCEPTANCE`, `PROBE_DIRECTORY` | `scripts/tests/test_supervisor_relaunch.py`: opt-in native relaunch acceptance and probe output path. | Exact `1` enables native test. Harness sets path. Unset skips acceptance. | No. Test only. |
| `PERSONASTACK_SIGNING_FIXTURE_PASSWORD` | `test-signing-continuity.sh`: generated disposable fixture password. | Helper generates/exports it for its child. Not an operator credential. | Secret fixture value. Test only. |
| `FIXTURE_LOG`, `FIXTURE_EXISTING_RELEASE`, `FIXTURE_RELEASE_FAILURE`, `FIXTURE_SIGNING_FAILURE`, `FIXTURE_VERIFY_FAILURE` | `scripts/tests/test_homebrew_release.py`: fake publication/signature subprocess controls. | Fixture supplied. Unset failure switches do not inject failure. No production meaning. | No. Test only. |
| `CALL_LOG`, `VERDICT`, `SUBMIT_EXIT`, `STAPLE_EXIT` | `scripts/tests/test_notarize.py`: fake notarization command output/status controls. | Fixture supplied. Not real notary configuration. | No. Test only. |

Tests also inject literal fake environment dictionaries for profile/projection behavior. Those arbitrary fixture keys are not operator-supported configuration. No build, test, signing operation, live service or credential read was performed for this documentation audit.

## Maintenance

Update this inventory when adding, changing or removing a reader, wrapper, generated child environment, workflow mapping or default. Keep `SPEC.md` linked here. This internal developer/operator reference changes no public customer workflow. No public-doc generation is required.


### Native setup resource disclosure

The existing unfiltered private helper `status` may include `local_cluster_requirements` only for an initialized local runtime. Its numeric fields are `cpus`, `memory_bytes`, `disk_bytes`, `initial_download_bytes`, and `minimum_host_memory_bytes`. Values come from Go runtime options and pinned installer artifact sizes. No environment variable or Swift fallback selects this budget. Native setup uses a separate strict requirements reader. Emergency control-version reads ignore this optional metadata so missing or malformed resource disclosure cannot block Stop or Remove.

Fresh Install first enables/reads back the existing helper. It then checks physical RAM and active CPUs against the supplied minimum and obtains native consent before key creation, downloads or VM startup. The dialog describes the sparse virtual disk maximum, configured RAM/vCPUs, minimum physical RAM, initial runtime download and extra provider-image downloads. Cancel performs none of those setup effects. Existing-data Repair and ordinary Resume, Stop and Remove keep their existing flows. The dialog also explains background execution after app Quit/sign-out and the awake, network-connected, logged-in macOS requirement. These are conservative configuration policy inputs, not an available-RAM prediction or a claim that all minimum-sized Macs passed native acceptance.
