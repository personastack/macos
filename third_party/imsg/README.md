# Bundled iMessage provider source

The app uses imsg v0.19.1 at commit `41de9c8b58ffbff2beff9ce3992192d5c11a753e`, plus the reviewed PersonaStack patch. `manifest.json` pins the source archive, dependency lock, patch and adapter revision. The MIT license is retained in `LICENSE`.

The installed app never downloads source or finds an `imsg` executable on PATH. Source preparation is a build-time operation. It refuses an existing output directory and verifies every pin before applying a patch. It rejects archive traversal, links and extraction-budget overflow.

Prepare source on the build host:

```sh
python3 third_party/imsg/prepare.py --output /tmp/personastack-imsg-source
```

An already downloaded archive can be provided with `--archive`. The same digest is required. Build with Swift 6.2 against its committed `Package.resolved`; do not silently resolve newer dependencies. The pinned SQLite.swift closure does not compile under Swift 6.1 strict concurrency. Swift 6.2 provides the required Dispatch conformance; no dependency annotation or global concurrency setting is weakened.

The patch adds finite private stdio RPC operations:

| Method | Purpose |
| --- | --- |
| `personastack.initialize` / `personastack.status` | Read-only database readiness without optional bridge IPC or Contacts calls. |
| `personastack.send` | Fixed selected-chat AppleScript text dispatch acknowledgement. |
| `personastack.chats.page` | Bounded metadata keyset pages and name/participant search. |
| `personastack.chatMetadata` | Exact selected-chat labels, participants and group metadata without message reads or inventory scans. |
| `personastack.source_checkpoint` | One read snapshot of numeric insertion high-water and selected-chat anchors. |
| `personastack.receive_page` | Exact selected-chat ROWID pages with conservative continuation. |
| `personastack.recent_messages` | Bounded selected-chat recent context without unbounded reply, audio or poll enrichment. |

`personastack.initialize` and `personastack.status` advertise `personastack_adapter_revision: 2`. The app never uses the upstream generic readiness verbs, which may consult an already-running private bridge. The existing headless `rpc` startup retains upstream authorized optional contact-cache behavior but does not request Contacts permission. Our finite handlers never consult that cache. Custom cursor selectors and results are canonical decimal strings. The host remains responsible for current API scope, native account identity and database generation. This CLI does not grant access based on a config ID.

`personastack.chatMetadata` accepts only `{chat_ids: [canonical positive decimal strings]}` with 1..32 unique IDs. It returns `{chats: [...]}` in the exact requested order and cardinality. Each row has the existing `id`, `guid`, `name`, `service`, `is_group`, `available` and `participants` fields plus optional SQLite `account_id`/`account_login` hints. Missing, unsupported or oversized conversations use a canonical unavailable row: requested `id`, empty `guid`/`name`/`service`, false `is_group`/`available`, empty participants and absent account hints. These hints never establish live account identity or generation. The checkpoint shape remains unchanged.

The exact metadata operation shares a conservative 512-record budget across chat metadata queries and participant records. Every requested ID is resolved or the whole operation fails. Exhausted time, row or output budgets never return partial results or an invented cursor. The one-second SQLite interrupt and one-MiB encoded-result budget also apply. Chat fields and participant values are bounded to 256 UTF-8 bytes. A chat with more than 100 participants is explicitly unavailable. No message body or whole-account picker is queried.

Reads use the existing IMsgCore SQLite connection and attributed-body decoder. Each operation runs in one read transaction. A one-second owned interrupt bounds SQLite work. A selected message read examines no more than 512 physical records. Body lengths are checked before loading attributed text. Text is capped at 16 KiB with an explicit truncation flag. Responses have a one-MiB normalized budget. Filtered rows advance the scan cursor; an omitted eligible record never advances it. Any interrupted or failed transaction returns no accepted cursor. URL preview rows are suppressed only when upstream `canCoalesceURLPreview` proves a matching predecessor in the same selected chat. Each proof examines at most 32 predecessors and shares the 512 physical-record budget. Unmatched, truncated or otherwise unproven URL content stays visible. A row deferred at the physical limit does not advance the cursor. Sender projection reuses upstream schema-aware `senderSQL`. Outgoing rows without a bounded `destination_caller_id` return an empty sender because the joined handle is the recipient. Incoming rows without a bounded handle also return an empty sender.

The custom provider does not read unselected message bodies, request Contacts access, convert attachment files, invoke private helpers or change SIP. P0 output includes only an attachment count and an empty metadata array. A later bounded metadata projection must not introduce attachment paths or file reads. The private send handler executes a fixed public AppleScript handler inside the owned provider process on MainActor. Typed NSAppleEventDescriptor arguments carry the selected GUID, text and required `expected_account_id`. The public account ID must be nonempty, control-free and no more than 256 UTF-8 bytes. It creates no osascript subprocess, so the host's provider-group cleanup cannot leave a separate sender process behind. The fixed script targets `/System/Applications/Messages.app`. Immediately before dispatch it verifies the exact live chat ID, the exact expected public account ID, iMessage service, enabled flag and connected status. Both IDs use case-sensitive comparisons. The iMessage service is fixed and SMS fallback is disabled. It bypasses upstream SentMessageVerifier and its potentially unbounded text scan. Any pre-dispatch validation/compile failure is not_started. Execution errors remain may_have_completed. The host's existing 45-second deadline bounds a hung script by terminating the owned provider. Its submitted acknowledgement never claims a message GUID. The native client alone confirms against bounded new rows above its captured source tail. The upstream standalone commands remain available to standalone users and are not routed by the app.

Focused synthetic tests:

```sh
python3 -m unittest discover -s third_party/imsg/tests
swift test --package-path /tmp/personastack-imsg-source --filter PersonaStack
```

Run compilation and tests on the selected remote build host. The Swift corpus uses only per-test synthetic databases. It does not open the real Messages database or send messages. macOS and Linux compile this dedicated test target. The semantic matrix compares ordinary, outgoing, matched/unmatched URL and tombstone content with the upstream reader on synthetic fixtures. Separate fixtures cover unknown local identity, absent schema columns, missing incoming handles, unavailable conversations, URL page boundaries and the shared physical scan budget. Unknown sender output is an intentional safety difference from upstream recipient fallback.

The manifest intentionally records `artifact_status: not_built` and no artifact digest. No signed binary is committed. Packaging must record the actual output hash, verify its macOS signature and preserve the app's responsible identity. Source tests do not prove Full Disk Access attribution, Automation consent, Apple account evidence, lock/clamshell behavior or the signed update path. Those remain P0/native acceptance gates.

## Build artifact bundling

The app packaging owner calls:

```sh
python3 third_party/imsg/bundle.py --app-bundle build/PersonaStack.app --build-root build/imsg
```

`--archive` can reuse the exact pinned download. Every invocation owns a unique temporary source/scratch directory. Swift 6.2 builds only `imsg` for `arm64-apple-macosx14.0` in release mode with automatic dependency resolution disabled. The script rejects other executable architectures. It does not sign, notarize, tag or publish.

The executable goes to `Contents/MacOS/imsg`. Actual SwiftPM resource bundles go to `Contents/Resources`. Relative aliases beside the executable support its generated `Bundle.module` lookup. The bundler rejects missing phone metadata, unexpected resource bundles, code hidden in data bundles, oversized receipts and existing output paths. Actual resource resolution inside the signed Mac app remains a native acceptance gate.

`Contents/Resources/imsg-provider-manifest.json` records the source and patch pins, target, toolchain, unsigned executable hash, current executable hash and resource file hashes. The package owner signs the nested CLI before sealing its resulting bytes:

```sh
python3 third_party/imsg/bundle.py --app-bundle build/PersonaStack.app --seal-existing
python3 third_party/imsg/bundle.py --app-bundle build/PersonaStack.app --verify-existing
```

Sealing updates the current executable hash and marks the receipt `sealed`. It never performs or substitutes for signature verification. The package owner then signs the containing app so the receipt/resources are covered. `verify-existing` checks the pinned identity and sealed bytes. The existing app signature verifier separately checks the real nested signature and designated identity. No build receipt claims production or provider qualification.

## Dependency notices

The bundler copies four fixed notice files into `Contents/Resources`. `manifest.json` pins their exact source bytes and immutable upstream provenance. The artifact receipt records the same fixed `notices_sha256` map. Every install, seal and verification checks those pins. Each file is limited to 32 KiB and their combined size to 64 KiB. Missing, changed, linked, unknown or oversized notices fail. Verification never restores a notice or changes the receipt.

| Bundle file | Pinned component |
| --- | --- |
| `imsg-MIT-LICENSE.txt` | imsg 0.19.1 and Commander 0.3.0. Their complete MIT texts are byte-identical. |
| `imsg-PhoneNumberKit-MIT-LICENSE.txt` | PhoneNumberKit 5.0.12. |
| `imsg-SQLite.swift-MIT-LICENSE.txt` | SQLite.swift 0.17.0. |
| `imsg-libphonenumber-APACHE-LICENSE.txt` | The libphonenumber 9.0.41 metadata included by PhoneNumberKit. |

The three files in `licenses/` are verbatim upstream license copies. They total 12,416 bytes. PhoneNumberKit's pinned original metadata XML is byte-identical to libphonenumber 9.0.41 at commit `b68df884d42d5e9860fc1956a99ce6afae361100`. Its header identifies `Copyright (C) 2009 The Libphonenumber Authors` and Apache 2.0. The packaged JSON remains unchanged. Its source and resource hashes are recorded in `metadata_provenance`. That upstream tree has no `NOTICE` file.

CSQLite 3.53.4 remains in the pinned dependency lock. The macOS provider does not embed it. The direct imsg product dependency is Linux-only and SQLite.swift's macOS default selects `SystemSQLite`. The signed macOS provider links `/usr/lib/libsqlite3.dylib`. These notices cover the bundled provider closure. Existing app-owned Sparkle and Yams attribution is separate.

The in-process transport uses only Apple's public [NSAppleScript handler execution API](https://developer.apple.com/documentation/foundation/nsapplescript/executeappleevent(_:error:)). No message text is interpolated into source. Linux tests fake the finite sender and verify that neither the upstream Process-based sender nor its unbounded receipt verifier runs. Actual MainActor execution, permission attribution and locked-session behavior remain signed macOS acceptance gates.
