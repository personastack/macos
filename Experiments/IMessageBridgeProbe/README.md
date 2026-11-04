# iMessage provider check

This fixture proves the P0 provider boundary before cloud setup is exposed. It uses one explicitly selected, non-sensitive iMessage conversation. It permits one explicitly confirmed fixed-text send per probe session. It has no background send, retry queue, database picker, permission reset, private framework action or listener.

The SwiftUI screen must run **inside the actual signed PersonaStack app**. A separately signed probe app, Terminal, an SSH process or a unit test does not qualify PersonaStack's Full Disk Access or Automation attribution. This directory's standalone Swift package is only a coordinator-policy test harness. It cannot produce signed-app or hardware proof.

## Host integration

The app owner wires the fixture after the common finite provider adapter exists:

1. The root package owns `IMessageBridgeProbe` with its `PersonaStackCore` dependency and the real PersonaStack executable includes that target. Its `IMessageBridgeProbeTests` target also depends explicitly on `PersonaStackCore`. The experiment package remains independent for coordinator-only policy tests. Do not create another app bundle or a second signing identity.
2. Add one explicit local diagnostic entrypoint. It must not be a WebView bridge action, automatic startup task or remotely supplied command. Merely opening the diagnostic screen must not invoke a provider request or permission prompt.
3. Resolve one authorized existing conversation through the metadata-only native selector. Require an explicit local choice when names are ambiguous. Construct `ProbeTarget` from its exact chat ROWID, current account ID, native source generation and display name. These values stay in memory. Do not accept a database path or an account ID from a hosted page as proof.
4. Construct `IMessageRPCClient` with `IMessageSubprocessTransport` using the real bundle's pinned provider resource. Pass the client and the exact `ProbeTarget` to `CoreProbeBackend`. This backend starts the child when the user clicks **Verify Messages**. It never substitutes a PATH binary or raw RPC method.
5. Supply the backend's `liveAccount` closure using the host's **fixed public Messages account probe** and native file/source-continuity owner. Its Boolean is permission intent: `true` is allowed only after the explicit **Verify Messages** action; `false` must never prompt. Resolve the exact selected conversation GUID through public Messages `chat.account`. Require its account to be connected, enabled and iMessage. Return that public account ID and exact `liveChatGUID`. Missing/ambiguous current account, chat/account linkage or unprovable source identity blocks the probe. Database account IDs and AppleScript account IDs are different evidence domains. Do not require or infer equal strings. The host calls `prepareProviderConnection(client)` before starting or reopening the provider. That stops the old descriptor and binds the fixed database's stable volume UUID, file number and birth evidence. Account observations refuse file/account changes inside that connection instead of returning a new generation for an old SQLite descriptor. The backend checks the exact live chat GUID against the selected source checkpoint and rechecks identity before and after reads/sends.
6. Present `IMessageBridgeProbeView(coordinator:)` in the real app's native diagnostic window. **Read selected conversation** is separate consent. The send screen gets its immutable approved target name from the coordinator that owns execution. It accepts no separate caller-supplied target label. Picker selection changes are disabled and rejected during verification. The send screen shows that approved name and the exact fixed test text. **Send one test message** is the only send action. Its coordinator owns the active action Task and consumes that session's one attempt before handing intent to the backend. Cancel cancels that Task, waits for provider shutdown and joins the operation before reporting completion. A pre-dispatch cancellation has no mutation; a possibly dispatched send remains unknown. Never rebuild it as an automatic retry after an unknown result.
7. The host must stop/reap the owned provider child through the common client when the diagnostic window is finally closed. Canceling a started send may return unknown and cannot prove no external effect. Do not kill another app's `imsg` or Messages process.

The fixture calls the common adapter for metadata/checkpoint/recent reads and forced AppleScript iMessage sends with SMS fallback disabled. The common RPC client verifies a newly observed exact text row after its pre-send source high-water, with matching selected chat, outgoing flag and GUID. The fixture adds exact public live-chat/account and source-generation checks around the action. It passes the public account ID as the shared client's required `expectedAccountID`. The provider checks that account inside its fixed script immediately before dispatch. A bare successful automation result, wrong/missing GUID, ambiguous identical rows, changed identity or incomplete receipt window yields **Outcome unknown**.

## Build and regression boundary

The root package owns native probe regression coverage. Its `IMessageBridgeProbeTests` target compiles the actual `CoreProbeBackendTests.swift` with `PersonaStackCore` available. Both `.github/workflows/validate-source.yml` and `.github/workflows/release.yml` include `[Ii]Message` in their native Swift test filters. That selector includes native iMessage tests and the fully qualified `IMessageBridgeProbeTests` module. Backend test functions need no iMessage name prefix.

Run the complete iMessage native source lane from the repository root on an approved Mac:

```sh
swift test --triple arm64-apple-macosx14.0 --disable-xctest --filter '[Ii]Message'
```

Local macOS builds are explicitly authorized for this project. Linux policy checks can still use the session-scoped Swift container on `eric-pc`. The workflows use `macos-26` runners. Their source-validation paths do not qualify signing or Apple permission attribution. The semver-tag release path continues into publication. Do not trigger it to obtain a diagnostic fixture.

The independent package is only a coordinator-policy harness:

```sh
swift test --package-path Experiments/IMessageBridgeProbe --disable-xctest
```

It intentionally has no `PersonaStackCore` dependency. Its `canImport` guards exclude the Core backend and backend tests. A passing standalone run does not replace the root native lane. These fake-provider source tests do not access Messages or prove the signed app's permission, lock, sleep or hardware behavior. Signed-app P0 acceptance remains separate.

## Consented signed-app procedure

1. Record the exact committed source, provider adapter/artifact digest, app digest, signing identity verification, macOS version/build and CPU architecture. Verify the actual app's pinned team-anchored designated requirement with the existing signature verifier. Keep account names, handles, selectors, paths and message bodies out of the report.
2. Use the real app in Applications. With the user's consent, enable that app's Full Disk Access and Messages Automation through normal System Settings. Add no Terminal/SSH grants for this check. Do not change SIP, privacy databases or the global power policy. Relaunch the same app only when the permission grant requires it.
3. Open the explicit diagnostic. Select the authorized existing test conversation. No other conversation body may be read. Click **Verify Messages**. A prompt may occur only as part of this explicit action. Missing/ambiguous account, database or adapter failure stops the fixture.
4. Click **Read selected conversation**. The fixture reads a bounded recent window from that one exact conversation and obtains scoped checkpoint evidence. It does not display or export message text. A missing retained message is a failure, not a silent success.
5. Review the selected display name and the fixed text `PersonaStack iMessage bridge test. No reply needed.` Click **Send one test message** only after the user has authorized this exact test recipient. The current task's single authorized recipient is held by the parent workflow, not stored in this source. Do not consume another authorization by restarting the fixture or trying another conversation.
6. Require **Outgoing message found in Messages** for local confirmation. **Outcome unknown** requires conversation inspection and no automatic resend. Local confirmation does not prove the recipient received the message. Record recipient observation separately when the parent acceptance flow requires it.
7. Copy the content-free receipt through the explicit button. It always states that external signature verification is required. Attach the separately verified app/provider identities and OS build. A copied JSON receipt alone cannot authenticate which app or backend produced it.

## Lifecycle evidence

Use subsequent **read-only** diagnostic sessions to inspect the approved conversation while locked but awake and in supported powered closed-display operation. Record the physical state and independent observation times. Do not infer lock, awake clamshell or system sleep from a healthy socket. One successful unlocked send does not prove locked sending.

An additional real send in another physical state needs another explicit user authorization. The current one-message authorization cannot prove sends in all states. Actual sleep suspends the app; it must not claim live availability. Full integration wake/reconnect, reboot/login, signed upgrade and 24-hour evidence belongs to the later main-app acceptance flow.

## Receipt interpretation

The schema-version-2 JSON contains only schema/run identity, bounded phase/failure enums, adapter revision, Boolean observations, update time and the fixed continuity scope `same_probe_session`. It contains no target ID, account ID, display name, recipient handle, local path, provider stderr, message text or outgoing GUID. `observed_checkpoint_continuity_verified` requires an earlier high-water and selected row/GUID anchor to survive a later observation. The first metadata snapshot alone cannot set it. Rollback, missing/changed anchor or source-generation change stops the provider and blocks further body reads through that backend. The check also brackets the selected body read before accepting its result. This is bounded continuity between observations in one probe session. The persisted opaque source identity is not a stored anchor chain or proof of replay continuity across app restart/reboot, and it cannot prove every in-place restoration detectable. `provider_probe_observation` is an observation class, not a signature or hardware attestation. Unit tests deliberately produce the same shape with a fake backend and always leave `requires_external_signature_verification=true`.

P0 remains incomplete while the real app's permission attribution, current account/source identity, controlled read/send, signed resource layout or required hardware state is unproved.
