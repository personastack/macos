# Locked-session invocation diagnostic

This kit tests a prerequisite for unattended Desktop Control: whether a public display-activity call causes macOS to invoke our mechanism in the real screensaver authorization flow. The mechanism always returns **Deny** immediately. It cannot unlock a Mac. It has no grant broker, password access, input injection, screen capture, or remote listener. The production app continues to reject locked control.

Use a dedicated test Mac with an administrator who can recover its authorization policy. Do not install this kit on the working development Mac. Building and running the fake tests changes no system permissions. The build does not install anything.

Apple's public activity API documents display power and sleep behavior. It does not promise an authorization transaction. A successful activity call is not unlock evidence. Cua's locked-control issue is a proposal with unresolved signing and integration questions. The experiment can fail on a particular macOS build. [Apple activity API](https://developer.apple.com/documentation/iokit/1557127-iopmassertiondeclareuseractivity), [Cua issue 1745](https://github.com/trycua/cua/issues/1745).

## Build

From this directory on a Mac with Command Line Tools:

```sh
probe_parent=$(mktemp -d /tmp/personastack-locked-probe.XXXXXX)
bash build.sh "$probe_parent/kit"
```

Compilation is serial at `nice -n 15`. The kit contains an arm64/x86_64 plug-in, a universal CLI, an offline plist composer, and this procedure. C tests use strict fake engines and activity calls under AddressSanitizer and UndefinedBehaviorSanitizer. Python tests check policy composition and removal. The only real CLI command executed by the build is `--help`.

The plug-in and CLI use development ad-hoc signatures. This does not establish Developer ID, notarization, host loading, or OS compatibility. `SOURCE.json` binds a clean source revision, source inventory, deterministic build ID, both loaded-image UUIDs and every shipped artifact hash. A dirty source build records no revision and cannot pass receipt verification. Build only the committed source before transferring the kit. Do not merge this plug-in into the production app or publish it through the production updater.

The diagnostic bundle's build version is now 2. Increase `BUILD_VERSION` in `receipt.py` when publishing another changed probe. The build and manifest use that single version. macOS can load a previous copy under `StagedPlugins`. A current installed path alone does not identify the loaded code. Every event includes its compiled build ID, a random plug-in instance ID and a process-local mechanism ID. The receipt checker also requires the loaded image UUID and exact sender bytes. Never remove Apple's staged files or disable SIP to make the test pass. [Apple staging discussion](https://developer.apple.com/forums/thread/835581).

## Dedicated-Mac procedure

1. Confirm normal manual locking and unlocking works. Record the exact macOS version and build with `sw_vers`. Keep a separate, tested administrator recovery route available before changing the screensaver policy. Local recovery must not depend on the lock test succeeding.

2. Inspect the kit. The only exported plug-in entry is `AuthorizationPluginCreate`. The mechanism identifier is `observe-screensaver`. Its only decision is Deny. The owned right is `ai.personastack.locked-session-probe`. The owned bundle is `PersonaStackLockedSessionProbe.bundle`.

3. Save the current policy on the dedicated Mac:

   ```sh
   security authorizationdb read system.login.screensaver > screensaver-before.plist
   python3 policy.py compose screensaver-before.plist screensaver-candidate.plist
   plutil -p screensaver-before.plist
   plutil -p screensaver-candidate.plist
   ```

   The composer writes only a new local file. It preserves existing policy fields and delegates. It adds our denying branch first with `k-of-n = 1`. An existing multi-delegate all-of rule is rejected. Keep the original file private. Do not change `system.login.screensaver.unlock`, login, console, FileVault, or any unrelated right.

4. Before touching the real screensaver policy, an administrator may install the reviewed bundle under `/Library/Security/SecurityAgentPlugins/PersonaStackLockedSessionProbe.bundle`. Refuse an existing bundle with that name. Use root ownership and normal non-writable bundle/executable modes. Do not replace another vendor's plug-in. Register **only** the new owned diagnostic right from `probe-right.plist`. Refuse an existing right with that name. Its leaf must retain `tries = 1`. Zero tries can retry Deny indefinitely in Apple's authorization engine. [Apple authd engine](https://github.com/apple-oss-distributions/Security/blob/main/OSX/authd/engine.m).

5. On that dedicated Mac, run the explicit preflight:

   ```sh
   probe_preflight_start=$(date +%s)
   ./personastack-locked-session-probe --validate-plugin --dedicated-mac
   probe_preflight_end=$(date +%s)
   python3 receipt.py inspect --kit . --start "$probe_preflight_start" \
     --end "$((probe_preflight_end + 1))" --require-load --dedicated-mac
   ```

   The expected authorization result is Denied. That status alone is insufficient. The receipt collects a fixed subsystem/category directly through `/usr/bin/log`. It accepts no caller-supplied log file as authentic OS evidence. It requires one ordered `plugin_loaded`, `mechanism_created`, `mechanism_invoked`, `denial_returned` sequence with matching build, instance, mechanism, host, sender and image UUID. The privileged mechanism must come from Apple's authorizationhost. SecurityAgent UI and fake test executables do not qualify. The candidate host path was checked against this development Mac's public Apple code-signing metadata. Other host paths and missing JSON fields remain unqualified until their OS layout is reviewed. Signature checks do not invoke an authorization request.

   The checker verifies only the exact owned installed or staged sender executable. It refuses symlink components, wrong ownership, writable binaries, stale bytes and image UUID mismatches. It reads no other vendor's plug-in or private data. Collection has a 15-second timeout and bounded scratch output. The interval must be positive and at most 120 seconds. If the bundle fails to load, the sender cannot be verified, or the authorization result is canceled/internal error, stop. Leave the real screensaver policy unchanged. Preserve the content-free receipt and exact OS build. A receipt is event correlation. It does not authenticate the transaction's purpose or prove unlock.

6. Review the original and candidate again. Re-read the live screensaver policy immediately before an administrator applies the candidate. If it changed, compose a new candidate from the new baseline. An administrator may write only the reviewed `system.login.screensaver` candidate. This is an explicit system-wide test change. The kit provides no installer or automatic authdb writer.

7. Perform one normal manual lock/unlock test. Verify our mechanism ran and denied before the original manual branch succeeded. If manual unlock breaks or the host reports an error, recover and remove our branch before continuing. A diagnostic custom-right invocation does not qualify the actual screensaver flow.

8. Start one delayed activity trial while unlocked:

   ```sh
   ./personastack-locked-session-probe --remote-activity-after 20 --dedicated-mac
   ```

   During the delay, use macOS's own Lock Screen command. Do not type or click at the locked Mac until the trial ends. No synthetic input or per-task approval is part of this test. The CLI makes one public activity call and releases only the assertion returned on success. An interrupted delay makes no activity call. It prints the compiled build ID, activity type and exact activity-call timestamps. Use `activity_started_unix` as the receipt's `--start`. Use an `--end` just after the completed activity observation. Collect before removing or replacing the plug-in. Requiring a new `plugin_loaded` event is unnecessary for later trials in an already loaded host, so omit `--require-load`. Creation, invocation and denial must still be present for one consistent mechanism in that trial interval.

   The operator must establish that the Mac was actually locked before that timestamp. The operator must also establish no local input, automatic authentication or other authorization request during the interval. A receipt alone cannot prove those facts. Record whether the real screensaver mechanism was invoked. The probe never authorizes an unlock. Ordinary authentication or another original policy branch can still succeed. Disable automatic authentication for the trial and record any unlock separately. An unexpected unlock is not a successful result for this probe.

9. Unlock manually. If remote activity did not invoke the mechanism, a separate trial may use `--local-activity-after 20 --dedicated-mac`. Record which activity type was used. Success for a local activity type does not establish remote-task behavior. Do not infer unlock, usable capture/input, Keychain access, privacy-cover safety, or relock from either trial.

10. Remove the experiment. First read the **current** screensaver policy and compose removal offline:

    ```sh
    security authorizationdb read system.login.screensaver > screensaver-current.plist
    python3 policy.py remove screensaver-current.plist screensaver-before.plist screensaver-remove.plist
    plutil -p screensaver-current.plist
    plutil -p screensaver-remove.plist
    ```

    The composer restores the exact baseline only when the current policy matches our composed candidate. Otherwise it removes only our delegate and preserves unrelated current branches and fields. Re-read the live policy before an administrator applies the reviewed removal. Do not overwrite concurrent changes with an old whole-policy dump. Confirm our delegate is absent and normal manual lock/unlock still works. Only then may the administrator remove our owned diagnostic right and bundle after confirming no other policy references them. Do not remove other vendors' rights or bundles.

## Results and remaining gates

Report source commit, build ID, binary hashes, OS build, activity type/status, verified authorization-host and sender-image identities/UUIDs, event timestamps, normal manual-unlock result, and removal result. No passwords, credentials, screenshots, or file contents belong in the report. The in-process event analyzer is fixture coverage only. Only the explicit dedicated-Mac collector can produce an OS-collected invocation receipt. No actual host loading or OS log collection is performed by the build.

A positive result qualifies only transaction initiation for that tested OS build and bundle identity. A negative result rules out this public trigger on that configuration. Full Desktop Control still needs an authenticated native grant path, bounded consent, every-display privacy, local-takeover handling, capture/input and Keychain proof, reliable return to the OS lock, signed packaging, and physical update-retention tests. The native checklist must keep Locked-Screen Control unqualified until those gates pass.
