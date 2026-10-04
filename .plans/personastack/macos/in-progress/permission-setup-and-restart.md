# macOS permission setup and restart

Status: installed locally. Native Quit, ordinary reopen and permission-relaunch acceptance passed. Goal blocked on menu-bar visual confirmation. No public release authorized.
Owner: `personastack/macos`, local checkout `macos-desktop/`. No tracker issue created.
Scope assumption: fix the original permission setup reports, including the later Quit failure. Deliver shutdown first.

## Objective and required outcomes

A macOS user opens Desktop Control permission setup, enables permissions, and sees current status without needing Check for each grant. Restart PersonaStack closes the old process and opens the same installed app in the foreground. Ordinary Quit also exits. Failed cleanup leaves a responsive app with a concrete recovery action.

- [ ] Restart returns the main window and menu-bar item. Ordinary Quit leaves no main app process. A later Applications launch succeeds.
- [x] Every `restartRequired` row has a yellow indicator. Copy distinguishes a required relaunch from verified permission approval.
- [x] Allowed notifications become green after one successful automatic delivery check. Changes made in Settings trigger bounded readback and applicable verification.
- [x] Full Disk Access Setup checks existing access first. Opening Settings does not unexpectedly open Finder or erase an existing approval. The user gets accurate instructions for adding the running app with +.

The smallest proof combines focused fake-based Swift tests with actual AppKit termination evidence. Calling the termination delegate directly cannot prove that its asynchronous work runs during a real Quit.

## Evidence and boundaries

- The report concerns another Mac. Its installed version and OS version are unverified. Logs and version 0.5.0 from this workstation are not evidence of that machine's failure.
- `PersonaStackTerminationDelegate.applicationShouldTerminate` returns `terminateLater` after scheduling both cleanup and its deadline as `Task { @MainActor ... }`. An isolated, windowless AppKit probe in this session reproduced starvation of both main-actor tasks and main-queue callbacks during actual termination. A modal-mode timer replied and exited. This confirms a source defect, not the remote machine's exact process state.
- `LocalRunManager.shutdown()` also waits indefinitely while a failed cleanup window remains registered. Its failure path must stay retryable without leaving the app permanently committed to quitting.
- Automatic notification setup deliberately skips `checkNotifications()`. The row requires delivery proof. An existing test asserts zero automatic deliveries, so it currently preserves the reported defect.
- Protected-access and LAN activation checks currently require prior successful proof. A first denial can remain stale after approval.
- Full Disk Access Setup resets before reaching the existing setup dialog. Its Settings helper explicitly reveals the bundle in Finder. Neither action adds an entry to macOS Settings.

Follow root and repository `AGENTS.md`, root and local `ADR.md`, and the owning `SPEC.md`. Keep native capabilities local. Preserve hosted authorization, enrollment, signing identity, and Sparkle ownership. No API endpoint or DTO changes are needed.

## Selected direct design

Fix the existing termination delegate for every Quit caller. Cancel the first termination request while its existing asynchronous cleanup runs on the normal main run loop. Once cleanup permits exit, request termination again. A small private phase gate allows that request to return `terminateNow` without repeating cleanup. Additional Quit requests during cleanup must not enter AppKit's deferred-termination loop.

Keep one cleanup owner and the existing distinction between ordinary Quit and Sparkle relaunch. A modal timer alone does not fix the main-actor cleanup pipeline. Do not move AppKit work onto a background thread. Keep the existing fixed permission restart script. Retain one running waiter and cancel it when cleanup fails. Independent review confirmed that an abandoned waiter otherwise relaunches on a later ordinary Quit. Repeated Restart reuses the waiter. Sparkle takes exclusive ownership when an update is ready.

Extend the checklist's existing checks for automatic verification. Opening the checklist and returning from permission Settings provide bounded verification opportunities. The three-second observation loop must not submit notifications, record audio, reset TCC, or repeatedly retry failed resource operations. Manual Check and automatic verification share the same operation owner and result mapping.

Full Disk Access uses the existing protected-access check and native setup sheet. Normal Setup must not reset this permission. Finder reveal remains an explicit separate action. macOS approval remains user-controlled. A successful Mail/Messages directory operation proves that operation, not universal file access.

Complexity budget: two existing owner families, termination and the permission checklist. No new packages, services, helper processes, persistent state, or cross-service contracts. Private quit/recheck state is acceptable. Remove the deadlocking deferred-termination path and converge notification verification. Touch local-run cleanup only enough to expose a failed close to its existing quit owner.

## Ordered phases

### 1. Restart and Quit finish through the native lifecycle

Acceptance: the old process exits after successful cleanup. Relaunch produces a usable foreground app. Cleanup failure preserves responsive recovery.

- [x] Change `PersonaStackTerminationDelegate` to the normal-run-loop cleanup gate above. Replace the deferred reply callback with one controlled termination request. Keep the deadline on that runnable loop.
- [x] Preserve local-run cleanup ownership. Return a failed cleanup result instead of waiting forever on a close that already failed. Keep failed local work visible and retryable. Do not force exit with a live local agent or unconfirmed credential revocation. If close is still genuinely pending, keep the UI responsive and report the pending work.
- [x] Keep permission Restart, menu/Dock Quit, and Sparkle restart on this delegate. Preserve one relaunch owner when an update is ready. Confirm that the initially canceled Quit does not abort Sparkle's retained install/relaunch handoff.
- [x] Preserve the instance lock, ordinary-Quit recovery suppression, foreground relaunch argument, saved environment, and main-window reopener. Do not resurrect a canceled enrollment request after restart.
- [x] Use `rg` to close every `PersonaStackTerminationDelegate` initializer and `reply(toApplicationShouldTerminate:)` caller in the app/tests. Remove obsolete delegate-only timeout assertions. Update `SPEC.md` to describe the new termination gate and retryable failure behavior.
- [x] Add focused tests for immediate and delayed cleanup, repeated Quit, successful exit admission, deadline behavior without active local work, failed local cleanup and retry, and Sparkle ownership. Fake local resources and updater callbacks. Assert no competing relaunch.

### 2. Permission approval appears automatically and truthfully

Acceptance: allowed notification delivery turns green automatically. Permission changes are rechecked without pressing Check. Restart rows are yellow and never claim unverified approval.

- [x] Route automatic Notifications setup through the existing bounded delivery verifier after authorization, alerts, and sounds permit delivery. Read settings again after delivery. Preserve denial, disabled alerts/sounds, rejected delivery, and cancellation.
- [x] Reuse presentation and activation hooks for one bounded verification after a relevant grant change or return from permission Settings. Include earlier denied protected-access/LAN rows. Deduplicate overlapping Check, Setup, presentation, and activation work. Retain generation, owner, document, and environment fences.
- [x] Verify microphone recording once after a newly observed authorized grant through the existing voice owner. Do not record on every activation or poll. Retain current capture exclusion and cancellation. Other automatic rows keep their existing login, updater, and power owners.
- [x] Render `restartRequired` yellow in the existing row view. Keep Ready green and preserve symbols/accessibility text. Reset success alone must not be presented as permission approval. Preserve optional rows' non-blocking Finish behavior.
- [x] Replace the test expecting zero automatic notification deliveries. Add coordinator workflows for denied → approved → verified and ready → revoked, changed notification settings during delivery, one check per trigger, stale callbacks, and closing/finishing during verification. Use injected OS and functional-check fakes.
- [x] Update `SPEC.md` for automatic delivery and bounded verification after Settings. Keep ordinary polling content-free. Review native row states without redesigning the window.

### 3. Full Disk Access Setup guides approval without surprise windows

Acceptance: an existing approval survives Setup. An absent entry gets clear manual-add guidance. Finder opens only from its named button. Current operation proof controls readiness.

- [x] Remove the unconditional Full Disk Access reset from normal Setup. Reach `setupProtectedAccess` and its existing Check Access / Open Settings / Cancel sheet. Keep reset behavior for unrelated permissions unchanged.
- [x] Make the Full Disk Access Settings helper open only the privacy pane. Keep Show PersonaStack in Finder as the explicit reveal action. Instructions identify the running bundle and explain +, selection, enablement, and any required relaunch. Do not automate macOS approval or promise silent list insertion.
- [x] Share the protected-directory check with phase 2's Settings-return verification. Preserve owner checks, no file-content reads, no entry-name retention, resource bounds, and optional setup status. Report missing resources or restrictions without claiming a grant.
- [x] Add strict-fake workflows for already-enabled access, absent/denied access, Check Access, Settings, Cancel, return after approval, relaunch readback, and revocation. Assert no TCC reset or Finder action during normal Setup/Settings.
- [x] Update Full Disk Access copy and `SPEC.md`. No legal-policy artifact or acceptance revision changes.

## Focused validation and acceptance evidence

- [x] Run freshly compiled focused tests once for the changed package. Consolidate selectors, for example `swift test --skip-update --filter '(quit|permissionRestart|permissionChecklist|permissionAutomatic|permissionNotification|notification|protectedAccess)'`. Adjust selectors to include every new primary owner. Do not use `--skip-build` as proof of changed source.
- [x] Inspect the diff for single-owner cleanup, permission state truthfulness, canceled work, unchanged signing/auth boundaries, and unrelated edits. Run `git diff --check`.
- [x] Define exceptional native acceptance separately from normal regression tests. An isolated windowless helper must invoke actual `NSApplication.terminate` and prove cleanup plus the deadline remain runnable. A parent bounds and cleans up only that helper. The existing probe is supporting evidence, not proof of the implementation.
- [ ] When installed-Mac acceptance is explicitly requested, record OS/app versions on the affected Mac. Check ordinary Quit, permission Restart, immediate reopen, Dock/menu-bar return, and the ready-update handoff where applicable. Batch notification approval/revocation, Full Disk Access manual addition and readback, yellow restart rows, and optional Finish behavior. Do not run real permission prompts or mutate the user's running app as part of ordinary tests.
- [x] Record native acceptance as passed or not run. Source tests do not establish installed-app relaunch, TCC attribution, or remote-Mac recovery. Archive the plan only when the required acceptance is addressed.

## Expansion and contraction

- **Now:** native shutdown scheduling, retryable local cleanup, notification verification, Settings-return checks, yellow status, and Full Disk Access guidance. These directly support the reported setup journey.
- **Later phase:** none outside the three ordered journeys above.
- **Defer:** the separate harness/skill-sync plan, local-container startup diagnosis, broader permission audit, and changes to the restart helper without separate evidence.
- **Block:** no product decision blocks source implementation. The affected Mac remains unavailable. This request authorizes a signed local installation for Eric to test. Automated native termination evidence and local launch/quit/restart acceptance are required. Remote TCC approval and ready-update installation remain user-owned follow-up checks, not claims of this implementation.
- **Contraction:** use the existing delegate, checklist coordinator, adapter, service, delivery owner, and protected-access sheet. No new relaunch service, permission database, monitor subsystem, or compatibility path.

## Non-goals and material risks

No public push, release tag, installer publication, deployment, legal-policy change, or `docs/ARCHITECTURE.md` edit. No automatic Full Disk Access approval, private TCC database writes, signing relaxation, forced termination of active user work, new crash recovery, or remote integration/enrollment mutation.

Sparkle handoff is the main integration risk of canceling the initial termination event. Prove it before phase 1 closes. Failed local cleanup remains an explicit safety boundary, not permission to strand an invisible app. Full Disk Access cannot be inferred from a Settings toggle or one unrelated readable folder. The other Mac's exact binary remains unverified until its version is recorded.

## Completion gate

- [x] Targeted validation is green: freshly compiled focused Swift tests.
- [x] Required contract and regression coverage is complete: native lifecycle and permission fake workflows. No changed HTTP endpoint or DTO, so the Go endpoint matrix does not apply.
- [x] Local review is clean: gaslight-loop over the completed implementation and tests.
- [x] Independent review is clean or not required: reviewer approval requested under AGENTS.md.
- [x] `$logic-patterns:adversary-loop` is clean after completed code and focused tests.
- [ ] Final build and applicable acceptance gates are green: signed local app, actual AppKit probe, workstation installation and native lifecycle acceptance. Real TCC changes and another Mac remain Eric's testing.
- [x] Tracker is in the required review state, if used: not used for this existing repo-local plan.

## Implementation and review evidence

- Native termination now cancels the initial request, runs one cleanup, and admits a new termination only after cleanup or the existing no-local-session deadline. Local-run failures return to a retryable phase. Failed/pending local chat windows stay visible. Intentional-Quit suppression is written only at exit admission.
- Caller inventory: five injected delegate tests plus the SwiftUI delegate adaptor. No `reply(toApplicationShouldTerminate:)` caller remains. Sparkle 2.10.0 source keeps its installer termination observer until the watched `NSRunningApplication` actually terminates. Its canceled request does not discard that observer. Existing prepared-update and permission-restart tests protect its exclusive relaunch owner. A real ready-update installation is deferred to Eric because this request does not authorize installing a different public release.
- Notifications share the existing delivery verifier. Notification approval/revocation, microphone denial-to-grant, protected-access Settings return/revocation, bounded LAN retry, cancellation, failed functional readback, and setup retries have fake-based regression owners. Full Disk Access Settings is opened only by its explicit sheet action. Tests reject reset/Finder effects.
- Initial CLT SwiftBuild could not load TestingMacros. The native compiler also needed its installed Testing framework search path. Verified both are present. Fresh validation uses `swift test --build-system native -j 2 --skip-update -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks --filter '(quit|permission|Permission|protectedAccess|microphone|notification|Notification|localNetwork|localRunClose|localRunLate|update|Update)'`. No cached-only proof.
- A 327-test pass was green in 10.303 seconds. Local gaslight review found stale microphone pre-observation state and overlapping LAN attempts. Guarded both and added an overlapping-check regression. That batch passed 329 focused tests in 8.331 seconds. The independent reviewer then found the two issues below. The repaired batch passed 332 tests in 21 suites in 15.601 seconds. Build output is `/tmp/personastack-repaired-tests.log`.
- `python3 scripts/tests/test_native_termination.py` passed actual `NSApplication.terminate` cleanup and deadline exit using the production delegate. The exceptional helper never opens user content, starts runtime work or requests permissions. Its parent bounds and cleans up only its own helper.
- Independent reviewer: Eric approved one GPT-6 Astra medium reviewer. That complete review returned the two findings below. Both are repaired. A fresh reviewer requires another approval. Until approval arrives, the final adversarial pass uses the skill's local fallback and records that limitation.
- No tracker is used. No endpoint/DTO, hosted authority, credential format, signing requirement, legal policy or release feed changed.

### Independent review ledger and repair

The approved GPT-6 Astra medium reviewer inspected the full tracked/untracked implementation, callers, tests, SPEC, ADR and plan. It returned two significant findings and no others.

1. Authorized microphone device/document loss cleared authorization history and could re-arm automatic recording. Preserve history for resource/document failures. Clear it only for observed OS denial, restriction or undetermined permission. Add a real-service coordinator workflow for missing/restored input, missing/restored document and later denial/approval.
2. Failed Restart retained a 300-second waiter, so later ordinary Quit could relaunch and another Restart could add a waiter. The existing restart owner now retains one pending process. Repeated requests reuse it. The delegate cancels it on failed cleanup. A ready Sparkle update cancels it and stays the exclusive owner. Fresh per-test owners cover failed Restart → ordinary Quit, failed Restart → successful Restart, duplicate requests and Sparkle takeover without spawning a process.

The fixed script, foreground argument and static request call remain compatible. This changes the plan's previously deferred waiter ownership only because review established a concrete defect in the newly supported failed-cleanup flow. No new helper process, package, service or crash-recovery guarantee.

### Local install preparation

- The current installed app remains version 0.5.0. A reversible backup is stored at `~/Library/Application Support/PersonaStack/LocalBuildBackups/PersonaStack-before-permission-fix-20261003.zip`.
- The local bundle stages source resources, pinned Sparkle 2.10.0, the installed Info.plist and a local provenance receipt. No public version, feed or release changes. The Developer ID identity and pinned certificate remain unchanged.
- Final product/test source fingerprint: `a41f87fc940814af58e90ee84257c6c2726d2a2ec34be5b47341ce2d4068e2cf`. Plan notes are excluded.

- This workstation's load exceeded 200 during validation. Use the freshly compiled native Debug executable for local testing, with Release signing entitlements and the same pinned Developer ID. The unused optimized build was canceled while queued. No publication is requested.

### Final stabilization receipt

- Fresh focused Swift validation: 332 tests, 21 suites, all passed in 15.601 seconds. The native Debug app executable was compiled from the final production code in that invocation. SPEC corrections after compilation affect documentation only.
- Local gaslight pass and a fresh complete adversarial fallback pass covered the final tracked/untracked code, caller inventory, tests, native acceptance helper, SPEC and plan. No significant unresolved findings. The two independent findings are repaired and covered by the fresh tests. No authorization, signing-pin or hosted contract changed.
- The independent review used the one GPT-6 Astra medium reviewer Eric approved. Fresh delegated review after repairs was requested but not approved. The adversary-loop fallback is local, as its skill allows. This is not a claim of a second independent approval.
- `git diff --check` passed on the exact final source. No commit, push, tag or release publication.

### Signed candidate and pending installation

- Local Debug app is staged at `build/local-testing/PersonaStack.app`. Existing scripts `sign-app.sh`, `verify-app-signature.sh` and `verify-sparkle-runtime.sh` all passed. The app and nested Sparkle code use the pinned Developer ID, hardened runtime, release entitlements and secure timestamps. No notarization or public release.
- The existing identity is in the registered backup signing keychain, not the login keychain. The saved signing-keychain password unlocked only that existing keychain. No credential values were printed, copied into the bundle, or changed. The interrupted initial signing left an owned temporary nested-code resource. The disposable staged Sparkle copy was refreshed before a clean full signing pass.
- Installed app PID 49864 remains live. CUA cannot find its window. LaunchServices reopen did not restore a CUA-visible window. Force-quit approval is pending before replacement. A sample shows a normal AppKit event loop, so this is not confirmation that the workstation app has the reported deferred-Quit deadlock. Source reproduction remains separate. Installation and installed-native acceptance are still unchecked.

- The final production-delegate native probe was rerun after stabilization. Both real AppKit cleanup and deadline exits passed again.
- Installation blocker clarified: current console session reports `CGSSessionScreenIsLocked = true`. This explains CUA window visibility. Force quit is unnecessary. Eric was asked to unlock this Mac for normal Quit, installation and native acceptance. No old process or installed bundle was changed. `/tmp/personastack-local-install-receipt.json` records the sealed executable hash and passed gates.

### Blocked audit

The same locked-console condition remained across three consecutive goal turns. Each continuation re-read current OS session state. The final check independently confirmed `CGSSessionScreenIsLocked = true` for the current console session. The old installed app remains PID 49864. The signed staged candidate still matches the final source receipt. No new source, test, review or artifact work is required before installation. Normal native Quit, replacement, foreground reopen and installed Restart acceptance require Eric to unlock the Mac. The plan stays in progress and the goal is blocked, not complete. Resume after unlock without changing scope or rebuilding unchanged source.

### Local installation and lifecycle acceptance

- Eric unlocked the Mac and explicitly requested the key from `.credentials`. The available archive variable is named `PERSONASTACK_INSTALLER_CERTIFICATE_P12_BASE64`, but its certificate is Developer ID Application. Its DER exactly matches the committed app signer pin. Loaded credentials only in the signing shell. Signed through one temporary keychain, then removed that temporary keychain. No credential values were logged or changed. No keychain password prompt occurred. The old orphaned SecurityAgent prompt had exited before replacement.
- The old app exited with normal native Cmd-Q. No force quit. Preserved the existing zip backup and moved its bundle to `~/Library/Application Support/PersonaStack/LocalBuildBackups/PersonaStack-before-permission-fix-20261003.bundle-backup` before replacing `/Applications/PersonaStack.app`. The installed bundle passes strict deep signature, pinned leaf, Team ID, designated requirement, hardened runtime, timestamp and Sparkle runpath checks.
- macOS 27.0. App metadata remains 0.5.0. This is the local Debug test build with provenance in `Contents/Resources/LocalBuild.json`. Its pre-sign executable hash matches the freshly compiled Debug executable. Final source fingerprint remains `a41f87fc940814af58e90ee84257c6c2726d2a2ec34be5b47341ce2d4068e2cf`.
- Actual installed normal Quit: PID 62317 exited. LaunchServices reopen produced a usable main window on the saved LAN profile.
- Installed permission-relaunch acceptance used the exact production `DesktopApplicationRestart.swift` in an exceptional temporary harness. It armed its normal fixed waiter for PID 79046. Native Cmd-Q drove the installed delegate. PID 79046 exited. LaunchServices started one PID 90917 with `--personastack-permission-relaunch`. CUA confirmed the foreground main window and saved LAN profile. This exercised the production script and installed cleanup/foreground startup. It did not click a restart-required row or reset a real grant.
- No actual TCC grant/reset, microphone recording, protected user-directory check, or ready-Sparkle update install was performed. Those remain Eric's explicit permission testing.
- User reported missing Back/Forward controls beside the traffic lights. CUA confirms both native controls are in the installed build. A plain AppKit probe of their exact owner puts them correctly beside the close button. That narrows the observed problem to main-window integration with SwiftUI hidden-title-bar styling. Existing navigation tests cover behavior and reuse, not visible placement. No header code was changed for this permission/restart fix.

### Remaining acceptance audit

- Yellow restart indicators: the shared row owner applies `Color.yellow` to `restartRequired` and green to complete rows. The installed executable matches the freshly compiled source receipt. Physical grant resets were not performed.
- Notification approval/readback: `notificationGrantChangeVerifiesOnceAndRevocationRemovesReady` passed. The shared automatic path invokes the delivery verifier and rereads current settings. Unchanged grants do not repeat delivery. The independent microphone and waiter findings have passing primary regression owners.
- Full Disk Access: `fullDiskSetupUsesExistingOwnerWithoutResetOrFinder` and `protectedAccessSettingsReturnAutomaticallyChecksThenBecomesReady` passed. Normal Setup bypasses reset. Settings and Finder use separate explicit actions. Strict fakes reject reset/Finder side effects. Real OS grant changes remain user-owned testing.
- One physical gate remains: the P menu-bar icon after relaunch. CUA exposes the main window and ordinary application menu only. Its screenshot is cropped to that window. The SystemUIServer and ControlCenter targets timed out. An independent read-only reviewer confirmed that source, assets, process state and source-wiring tests cannot establish the rendered icon. Eric's visual confirmation was requested once and is pending. No source or app mutation is needed merely to repeat these proofs. The plan is not archived while that requirement is unverified.

### Menu-bar blocked audit

The same physical menu-bar evidence gap remained across three consecutive resumed goal turns. The latest SystemUIServer observation again returned `timeoutReached`. Process inspection confirms SystemUIServer PID 631, ControlCenter PID 628 and installed PersonaStack PID 90917 remain live. That timeout is not evidence of a missing icon or a stopped app. The independent blocker review found no other available permitted surface that proves physical icon visibility. Eric's pending visual answer is required to close this gate or establish a remaining defect. The goal is blocked, not complete. Keep the installed build and plan in place. Do not rebuild unchanged source or restart macOS services.
