# Attempt desktop operations without unlock confirmation

## Objective and revised decision

Eric's 2026-10-02 instruction replaces the earlier detector proposal: attempt an authorized operation and return its error. Do not require an unlocked observation or a confirmation click. Do not reinterpret an absent macOS lock field as proof of unlock.

Scope: native macOS repository. No tracker issue created. No cloud DTO changes, persistent state, packages or services.

## Implementation

- [x] Remove the foreground confirmation dialog, menu entry, setup hooks and confirmation-specific error.
- [x] Let ordinary startup, permission preparation, command admission and recovery proceed for unknown and locked observations. Keep runtime identity, permissions, pause, current connection, lease, revocation, cleanup, sleep and inactive-login-session checks.
- [x] Keep the qualified locked-control supervisor's existing display privacy and actual unlock/relock proof. Preserve its cold daemon recovery path.
- [x] Attempt GUI requests through the authenticated owned driver despite degraded prior GUI readiness. Return the operation's failure even if a subsequent recovery probe reports a different error. Never replay mutating actions.
- [x] Keep raw lock observations truthful in status and diagnostics. Derive execution availability from runtime capability and authorization rather than `session_unlocked`.
- [x] Align `SPEC.md` and remove obsolete confirmation references from sources and tests.
- [x] Complete the focused session, runtime, permission, command, readiness and supervisor regression run. Include a stateful unknown/locked workflow covering lease acquisition, GUI and file success, actual GUI failure, recovery failure, no mutation replay, wrong lease, stale connection and pause.
- [x] Build, sign and install the updated application at `/Applications/PersonaStack.app`. Verify the pinned signature, Sparkle linkage, installed executable hash and launch survival. Preserve the previous app.
- [ ] Verify visible remote operation in the installed application. Source tests and launch survival do not prove OS behavior.

## Evidence and remaining limits

The locked-state implementation and native test changes are uncommitted follow-up work on `main`. The release request includes this implementation and the pending `0.5.0` changelog. GitHub Release and Homebrew cask versions were `0.4.0` when checked on 2026-10-02. The release tag is not created yet.


The combined focused Swift run passed 577 tests in 37 suites in 6.55 seconds after compilation. Log: `/tmp/personastack-operation-attempt-tests-final.log`. Final review removed an additional qualification-refresh status gate. Its 17 focused operation, verifier and supervisor regressions passed in 1.195 seconds. Log: `/tmp/personastack-operation-attempt-verifier.log`. The fixture workflow covers unknown and locked observations using generated driver responses and test files. Both normal operation failure and recovery-probe failure retain the original command error. A parallel run exposed an existing half-second child-shutdown wait; the test now awaits the same handshake with a five-second deadline. The supervisor IPC regression now pins the production five-second request deadline and exercises silent and partial frames with socket pairs. The first run of all 826 tests in parallel had 12 shell shutdown failures; the isolated 15-test `DesktopShellExecutorTests` rerun passed. GitHub release validation passed for source commit `3db4b7058cfcf4abf0f88218089992aae18f2552`: [workflow run 37095880498](https://github.com/personastack/macos/actions/runs/37095880498). This ran the repository's bounded native release suite, appcast fixtures, release-note validation, and arm64/x86_64 validation builds. `swift test --disable-xctest` cannot run on local Command Line Tools because the Testing macro plugin is unavailable. Python fixtures passed 32 tests. Release notes validate. `git diff --check` passed.

The earlier physical lock-field qualification is no longer a prerequisite for ordinary operation attempts. Full protected locked-control acceptance still requires the existing real-Mac privacy/unlock/relock checks. No public release or installer changes belong to this slice.

Local installation: Release build passed in 42.25 seconds. Signed candidate and previous app are in `/tmp/personastack-operation-attempt-signed-8eowk3md`. Installed executable SHA256: `3db6974a1acabc88b09e584ab286eef2b826cb8d77182bb8c4a2fe1d6a1b0e77`. Source fingerprint: `758990163731c0f7c929e89c4f3e2437464297a548f6b051da3023a226628cc6`. LaunchServices started PID 635. Dedicated signing keychain relocked. Version remains local 0.4.4. No policy/TCC changes or public release.

## Completion gate

- [x] Targeted validation is green on pushed source commit `3db4b7058cfcf4abf0f88218089992aae18f2552`; the native release suite and arm64/x86_64 validation builds passed.
- [x] Required regression coverage is complete: focused unknown/locked workflows cover operation attempts, errors, no replay, lease/scope fences, pause, and recovery.
- [x] Local review is clean after repairing the stale spec and release-menu fixture.
- [x] Independent review is clean after the full-surface adversary rechecked the final diff.
- [x] Adversary loop is clean after completed code review and focused validation.
- [ ] Final build and applicable acceptance gates are green: signed/notarized tag workflow, Homebrew publication, signed Sparkle feed, and visible remote-operation acceptance are pending.
- [x] Tracker is not used for this implementation slice.

Release prerequisite: GitHub Actions currently has no `PERSONASTACK_DEVELOPER_ID_INSTALLER_P12_BASE64` or `PERSONASTACK_DEVELOPER_ID_INSTALLER_PASSWORD` secret. The signing workflow requires the Developer ID Installer certificate before it can sign and notarize the package. 1Password is unavailable in this shell. Do not create the release tag until the required installer identity is configured and release validation succeeds.
