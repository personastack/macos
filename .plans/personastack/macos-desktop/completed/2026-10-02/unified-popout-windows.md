# Unified macOS pop-out windows

Issue: [PER-605](https://linear.app/personastack/issue/PER-605/unify-macos-chat-stream-and-console-pop-out-layout) — In Review (verified Linear update 2026-10-02)

Scope: `macos-desktop` and `my.personastack.ai`; chat, Stack Stream, and persona Live Console. Eric approved implementing the preceding design recommendation. Code-only review/validation: do not inspect or operate the desktop. No release or deployment.

## Design and boundaries

- One shared native compact titlebar with standard traffic lights, real window title, trailing Pin, normal shadow and native corners. Web content starts below chrome; no native overlays intercept hosted controls.
- Native owns window presentation and local geometry only. Website/API retain identity, authorization, content, sessions, streams, and chat-close authority. Reuse observed document titles instead of a new product-data bridge.
- Native advertises `window.personastackNativeWindowChrome = true` to hosted documents at document start. Hosted modules apply `data-native-window-chrome="true"` to the document element and suppress only duplicate titles/outer framing for that capability. Browser/Linux/older-host behavior remains functional.
- Expanded geometry is remembered locally by window kind (no saved transcripts, resource names, or session restoration); clamp restoration to available screens. Collapsed chat retains its avatar mode without overwriting expanded geometry. Graph retains its transparent widget behavior.
- Hosted chat keeps stack context and avatar collapse accessible in compact secondary chrome; its composer remains anchored. Console retains functional search/filter/follow controls. Narrow stream roster starts collapsed and remains operable.
- Root architecture and ADR were read. Service/data/auth/release ownership does not change, so root architecture needs no edit. Update both service specs. Legal: local window geometry only, no new external recipient, content retention, telemetry, or policy change.

## Checklist

- [x] Inspect native/hosted surfaces and existing unrelated edits; establish one tracker.
- [x] Native shared window presentation, title sync, pin/fullscreen/close behavior, geometry, and focused tests; update native SPEC.
- [x] Hosted capability-aware layouts, canonical titles, context/collapse affordance, narrow roster, and focused tests; update web SPEC.
- [x] Integrate and verify cross-repository title/capability contracts; preserve browser/Linux/graph and chat lifecycle behavior.
- [x] Run focused native, TypeScript, and in-process route/template coverage.
- [x] Fresh adversarial review; fix significant findings and repeat until clean.
- [x] Run applicable code-only build/final validation; record exact evidence and explicitly unrun visual/browser/live lanes.
- [x] Commit intended scoped changes, move issue to In Review, and archive this plan.

## Validation ownership

- Native in-process AppKit tests: chrome, geometry/clamping, pin state, title observation, collapse/expand, close/session disposal and graph preservation.
- Web Vitest: native capability and shared presentation behavior, title producers, roster behavior. Registered Go handler/template tests: existing pop-out GET routes and authoritative labels; preserve auth, methods, errors and escaping.
- No new HTTP mutation/DTO/API operation is planned. Idempotency/stateful-mutation categories are not applicable to presentation-only GET changes; existing chat-close behavior stays covered by its owning tests.
- No desktop inspection, visible-browser review, screenshots, live provider calls, deployments, or credentialed E2E. Automated source/DOM/AppKit evidence is not visual acceptance.

## Completion audit map

Each row needs implementation inspection and executable evidence before closure.

| Requirement | Artifact / evidence owner |
| --- | --- |
| Shared titlebar, three traffic lights, Pin, shadow and native corners | Native shared presentation helper plus both window managers; Swift window tests |
| Resource-specific title, no duplicate hosted heading | Native WebKit title observation plus hosted chat/activity/stack document-title producers; Swift title tests and web producer tests |
| Content below native controls, no intercepting drag overlay | Native constraints and AppKit layout assertions; capability-scoped hosted styles |
| Edge-to-edge chat/stream/console | Three hosted pop-out styles/templates and shared native capability helper; focused CSS/DOM contracts |
| Chat composer and collapse/context affordances | Shared chat presentation/session mounting; native collapse/expand/close tests and hosted DOM tests |
| Console search/filter/follow controls remain reachable | Activity pop-out styles and transcript integration tests |
| Narrow participant collapse and resize usability | Stack pop-out roster controller/CSS; initial narrow, user toggle and resize tests |
| Minimum size and remembered expanded geometry | Native geometry owner; isolated preferences, off-screen clamping, collapse/fullscreen tests |
| Graph/browser/Linux behavior preserved | No graph capability injection; graph native tests and absent-capability hosted cases |
| Authorization/session/close semantics preserved | Existing strict bridge checks and disposal tests; registered pop-out GET route tests and chat-close owner tests |
| Service specs aligned, unrelated edits preserved | Scoped SPEC diffs and scoped commits in both repositories; root architecture unchanged |
| Independent review clean | Fresh reviewer finding ledger and fixes with rerun evidence |
| Required code-only gates | Swift product build; web tested runtime build through Podman eric-pc; exact command/log/exit result |
| Tracking and closure | PER-605 In Review, archived checklist, final commit IDs, explicit visual acceptance limitation |

## Evidence and findings

- Final full tested runtime build PASSED: complete owning Go suites, coverage check/gofmt, default TypeScript typecheck, static preflight, all 172 TS files/2,850 tests, bundles and final linux/amd64 runtime image. Retained authoritative log `per605-web-build-complete.log`; web tests passed 82.082s, 74.2% coverage; contracts 88.2%. Image ID `sha256:9183cc460131cce341549fd75f00911b0998a84dcdef186f00f6313c4fd63a5c`; read-only Podman image inspection confirms linux/amd64 and revision `479824e2086a5592b8fe7b98b32974dd2949fc2e`. Build success/final image evidence supersedes unavailable historical focused Go output. No publication/runtime launch/deployment.
- Independent closure auditor `ses_f043837f9ffeD3WP6KfcP882RF` inspected committed source/test mappings and retained native/TS/prerequisite logs: sufficient requirement-to-evidence map, with only final runtime Go execution and tracker/archive closure pending. No additional required evidence gap. Visual/browser/live/release proof remains explicitly unrun.
- Retained full TypeScript log verifies 172 test files and 2,850 tests passed, plus default typecheck/static preflight/asset bundle. This supplements focused pop-out type diagnostics, not a claim that the repository's narrow default typecheck includes every pop-out module.
- Second prerequisite test-only repair committed `479824e20`: correct shared icon selector plus scoped 0.75rem Run Local dimensions. All three owning tests passed in offline Podman eric-pc Go1.26.1 (0.025s), `per605-icon-tests.log`. Fresh reviewer `ses_f043b83a9ffevH53T4HD9ibe2X` clean; no pop-out behavior changed.
- Exact Containerfile `ts-test` target passed: typecheck, static E2E preflight, bounded TypeScript build/unit tests and bundle. Log `per605-web-ts-gate.log`; image `e43b303feda959bac39b942b9307038adb8311bbdbc35f17e6e563997286c866` is test-only diagnostic. Full runtime gate now retrying after both stale baseline assertion repairs, log `per605-web-build-complete.log`; pending.
- Second full runtime attempt failed (exit 1): stale `TestPersonaDirectoryActionsShareCompactBluePresentation` expected selector grouping before independently committed Run Local icon resize (`72f6d05bf`/`2a991d2c0`). Independent diagnosis checked all 44 snippets across three tests: one stale selector only. Test-only repair assigned to preserve shared 1rem assertion and explicitly assert separate Run Local 0.75rem dimensions; no runtimeCSS/user-work changes. Concurrent exact Containerfile `ts-test` lane started to discover remaining independent gate failures without serial full rebuilds; log `per605-web-ts-gate.log`.
- Audit limitation: implementer's historical focused Go output path is no longer readable from this session (file not found). Its result remains a reported targeted pass, not independently verified persisted output. Final Containerfile runs the complete owning Go suites and its session-local log will be the retained authoritative regression evidence.
- Full gate prerequisite repaired in `7cbcdbc20`: exactly two stale provider button-label expectations now match independently committed `52af48002`, with no runtime changes or weakened assertions. Both targeted tests passed in offline Go1.26.1 Podman eric-pc (0.032s), log `provider-label-two-tests.log`. Fresh reviewer `ses_f044251c1ffemeUmhPCJwaNx3w` reports clean and verifies pop-out code unchanged from `37d0d836a`. Full tested runtime gate restarted at revision `7cbcdbc20`; log `per605-web-build-final.log`, result pending.
- Exact hosted focused Vitest command: `npm run test:ts -- assets-ts/packages/shared/native-popout.test.ts assets-ts/packages/persona/persona-chat-desktop.test.ts assets-ts/packages/persona/persona-console-desktop.test.ts assets-ts/packages/stacks/stack-stream.test.ts --maxWorkers=4 --minWorkers=1` (87 passed). Repair command: `npm run test:ts -- assets-ts/packages/shared/native-popout.test.ts assets-ts/packages/persona/persona-console-desktop.test.ts --maxWorkers=2 --minWorkers=1` (CSS 13/13 plus console passed). Focused Go/parity output persisted at `/Users/eg/.ai/eg/opencode2/data/opencode/shell/4b896e020525c4c3f49d74525309066898cdb1af/sh_0fba06836001l348ObvVyHHOjX.out` (web 1.473s).
- Native slice committed as `ebefbb4` (`feat: unify native popout window presentation`). Only native managers/shared presentation/tests and pop-out SPEC hunks were staged. Unrelated Desktop Control, release and source-repository edits remain untouched.
- Requirement audit inspected actual CSS cascade tests: Stream footer compares browser and native radii at 1000/720/390px; console uses the real transcript renderer root and asserts zero native border/radius plus scroll/flex controls; chat keeps stack link and avatar while hiding duplicate title. These are DOM/source assertions, not rendered visual acceptance.
- Endpoint/DTO commit declaration: changed activity GET adds a scoped canonical persona identity read; three pop-out GET templates import native stylesheet; chat bootstrap adds optional `persona.stack_id`/`persona.stack_name` from its already-owned settings read. Focused Podman command passed: `go test -p 8 -parallel 30 ./internal/web ./internal/web/contracts -run 'Test(NativePopout|DesktopChat|DesktopStack|DesktopPersonaActivity|UITimestamp|PageTemplatesImportExpectedCSSAssets|PersonaChatBootstrapOwner|.*RouteOwnership)' -count=1`. Registered handler fakes assert scoped methods, routes, headers, identity, escaping/denial and no protected label leakage. No new mutation contract.
- W1 fixed: composer/send-help now have capability-scoped zero radius. Actual stylesheet cascade tests cover 1000/720/390px; 13 shared capability/CSS tests plus console tests passed. Fresh whole-surface hosted reviewer `ses_f044e312cffeXyvwcd5mR85u2E` reports no significant findings.
- Final native product build passed exit 0 in 9.42s with `nice -n 10 swift build --product PersonaStack --build-system native -j 2`, isolated scratch plus CommandLineTools Testing framework/plugin/linker paths. Evidence `popout-native-20261002-astranative-build.log`; compiled debug PersonaStack artifact exists. No app launch or signed installer proof.
- Final web tested runtime image build through Podman eric-pc failed (exit 1) in full Go tests: `TestAIProviderOpenAICompatibleAddFormUsesAPIKeySetupMarkup` and `TestAIProviderOpenAICompatibleSettingsUseAPIKeySurface`. Log `per605-web-build.log` under approved session temp. Pop-out focused tests passed; unrelated provider markup failure independently delegated for diagnosis. No skipped gate or user-work reset.
- Hosted slice committed as `37d0d836a` (`feat: flatten hosted native popout layouts`), 24 scoped files including only pop-out SPEC/bootstrap-context hunks. Concurrent provider work was committed independently as `52af48002`; no provider files are in this task commit.
- Native completed: `PopoutWindowPresentation.swift` shared dark native toolbar, 48–52pt in-process measured height, three traffic lights, Pin, observed title and bounded kind-specific geometry. Managers/tests/SPEC aligned. 16 Swift tests passed, verified in `popout-native-20261002-astranative-verify.log` under session temp. Fresh final native reviewer `ses_f04546004ffeAreJ3XI2Tl6ShC` reports no significant findings. Fullscreen is simulated; visible behavior remains unrun.
- Hosted completed: shared native capability/style, canonical titles, optional BFF stack context from existing authorized settings read, console controls and narrow roster. 87 Vitest tests plus 8 CSS rechecks passed; selected registered-handler/template Go tests passed in offline Go1.26.1 container on eric-pc. Generated chat contract matches container generator; gopls/diff checks passed. Scoped TS diagnostics are inherited ES2020 replaceAll, persona-avatar nullability and stack-stream element typing; no added-code diagnostics.
- Fresh hosted reviewer `ses_f04588aa5ffeLoQHfp7c52n07s` found W1: compositor/send-help footer radii survive outer flattening in actual Stack Stream stylesheet, producing nested rounded card cutouts. Assigned batch fix with actual CSS cascade coverage; fresh re-review required after repair.
- Cross-repository capability inspection: native `PopoutWindowPresentation.advertise` installs the main-frame document-start Boolean `personastackNativeWindowChrome`; hosted `packages/shared/native-popout.ts` accepts strict `true` plus the existing Macintosh/PersonaStackDesktop/1 user-agent and applies the agreed HTML data attribute. This is presentation selection, not an authorization gate. Executable cross-surface tests remain pending implementer results.
- Code-gate audit by `ses_f04618115ffehpjenwFncXnA34`: the normal web Containerfile runtime target includes Go tests/coverage/gofmt, TypeScript/unit/static checks, asset bundling and runtime compilation without browsers or deployed services. Final command will use `PODMAN_CONNECTIONS_CONF=/Users/eg/.config/containers/podman-connections.json podman --connection eric-pc build --target runtime --platform linux/amd64 --build-arg RUN_TESTS=1 --build-arg APP_VERSION=dev --iidfile <session-temp>/web-image-id -f Containerfile .`, with session-local logs. No publication or version tag is needed. Native final compilation uses session-scoped Swift scratch storage and bounded low-priority compilation. Compile success is separate from selected native test execution. The web's default typecheck covers persona-settings only, so pop-out module typing must be checked specifically.
- Integration finding N1: native unified toolbar initially inherited system appearance over permanently dark hosted content. Light-mode Macs could retain a contrasting light titlebar. Native implementer owns the correction and configuration regression assertion. Visual verification remains intentionally unrun.
- Baseline review: native chat has a 40pt strip plus hosted identity/card inset; stream/activity hide traffic lights and intercept a 48pt overlay; both disable shadows. Console retains nested outer borders. Shared native chrome and capability-scoped hosted layout are the selected narrow shared fixes.
- Native implementation delegated to `ses_f04722de6ffeytEeKvzU7KPsE7`; hosted implementation to `ses_f0471c131ffeuOA4CicrD7Svrx`. Each owns its repository slice and focused SPEC changes. Existing Desktop Control and provider/profile edits are unrelated and must be preserved.
- Final native code gate: Swift build of the PersonaStack product plus focused in-process Swift Testing coverage. Signed installer/notarization/TCC and hosted UI smoke are separate, unrequested release/visual evidence.
- Container preflight corrected: OpenCode's XDG_CONFIG_HOME hides normal Podman configuration. `PODMAN_CONNECTIONS_CONF=/Users/eg/.config/containers/podman-connections.json podman --connection eric-pc info` reaches EricPC, linux/amd64, 30 CPUs. No configuration changed. Eric explicitly reaffirmed Podman on eric-pc; no local Go substitute is authorized.

## Exact final gate commands

Native working directory: `/Users/eg/git/personastack/macos-desktop`.

```sh
nice -n 10 swift build --product PersonaStack --build-system native -j 2 --scratch-path /private/var/folders/37/c96nn5v55rq1mxdj3vvtnb6h0000gn/T/opencode/popout-native-20261002-astranative -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib -Xlinker -F -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks -Xlinker -L -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Web working directory: `/Users/eg/git/personastack/my.personastack.ai`.

```sh
PODMAN_CONNECTIONS_CONF=/Users/eg/.config/containers/podman-connections.json podman --connection eric-pc build --pull=missing --platform linux/amd64 --target runtime --build-arg TARGETOS=linux --build-arg TARGETARCH=amd64 --build-arg RUN_TESTS=1 --build-arg APP_VERSION=dev --build-arg APP_REVISION="$(git rev-parse HEAD)" --iidfile /private/var/folders/37/c96nn5v55rq1mxdj3vvtnb6h0000gn/T/opencode/per605-web-image-id -f Containerfile .
```

Both gates redirect output to the retained session-temp logs named above. No publication, git version tags, credentials, application launch, deployed runtime, browser or live provider is involved. The user's code-only constraint makes visual/browser/live release gates inapplicable to this implementation; those lanes are intentionally unrun, not claimed green.
