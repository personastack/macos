# macOS desktop automatic updates

Status: in progress. The source implementation and main functionality checks are complete. The updater builds for arm64 and x86_64 in release mode against the cached Sparkle framework. A fresh disposable universal app bundle passes `verify-update-bundle.sh`. Thirty-one focused tests pass across four suites, including read-only startup and failed-install cleanup. Two Python appcast fixtures pass. Sparkle's real generator created embedded release notes and archive/feed signatures from a disposable app using a throwaway key, and both signatures verified. A temporary DMG payload was mounted and checked, and the packaging Finder AppleScript compiles. Fresh full-surface review found no significant findings after fixes for Sparkle's quit-time install behavior from read-only or translocated copies and stale foreground-relaunch metadata after install failure. Configured release-key signing and installed update journeys remain unverified. No release DMG or public release was published.
Owner: `personastack/macos-desktop`. Supporting repository: `personastack/homebrew-tap`.

## Outcome

A person who installed PersonaStack through Homebrew or the website DMG can discover an update, confirm a download, keep working, and use the update after restarting. An optional setting downloads updates automatically. An existing valid login survives the restart.

Success requires an installed old-to-new update from both installation methods. Source tests cannot prove bundle replacement, macOS authorization, relaunch, or WebKit session persistence.

## Selected design

Use one Sparkle 2 updater per app process. Homebrew and DMG installations contain the same updater-enabled bundle. Sparkle owns scheduling, downloads, verification, staging, replacement, and relaunch. PersonaStack owns its dropdown, reminders, and restart confirmation.

Publish `appcast.xml` in the public Homebrew tap. Generate it from the same release version and final DMG used to generate the cask. Its archive URL selects the immutable `desktop-vVERSION` artifact. The app reads this feed instead of parsing Ruby casks or querying GitHub's latest-release API. The current public cask uses this versioned artifact convention. [Public cask](https://raw.githubusercontent.com/personastack/homebrew-tap/main/Casks/personastack.rb)

Pin Sparkle 2.10.0, the current stable release inspected for this plan. Its macOS 12 minimum fits PersonaStack's macOS 14 requirement. Recheck security releases when implementation begins. [Sparkle release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)

Subclass `SPUStandardUserDriver` so Sparkle retains its confirmation, release notes, progress, cancellation, and error UI. Override the ready presentation with a PersonaStack alert offering **Restart Now** and **Later**. Sparkle handles the prepared update and replacement. Gentle reminder delegates alone cannot provide the requested **Later** action. [Standard driver source](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUStandardUserDriver.m#L476-L485)

Add `auto_updates true` to the generated cask. Sparkle updates the actual installed bundle. There is no installation-source branch, Homebrew subprocess, or receipt rewrite. Homebrew supports self-updating casks and compares readable app bundle versions. Homebrew pinning does not disable an app's own updater. [Cask cookbook](https://docs.brew.sh/Cask-Cookbook), [Homebrew FAQ](https://docs.brew.sh/FAQ#how-does-brew-upgrade-handle-apps-that-update-themselves)

### Scope and complexity

| Dependency | Classification | Treatment |
| --- | --- | --- |
| Increasing bundle versions, Sparkle embedding, signed DMG and feed | Now | Required trusted update path |
| Dropdown, daily checks, reminders, automatic update preference | Now | Discovery and consent journey |
| Prepared update, normal quit, Restart Now, login preservation | Later phase | Phase 3 completes the restart journey |
| Ed25519 private key in release secrets with a protected backup | Block | Required before real signed update publication. Does not block coding against fixtures |
| Developer ID signing and notarization | Defer | Separate distribution improvement. Validate the current unsigned path before claiming seamless installed updates |
| Beta channels, delta downloads, forced updates, polling while fully quit | Defer | Outside this journey |

Budget: two repository owners, one new external package, one updater coordinator, one presentation adapter, and one small native toast surface. Refactor the existing notification owner in place. Sparkle owns update preferences and staging. At most three local presentation preferences cover reminder deduplication, last displayed version, and foreground restoration after an update restart. No database, API contract, hosted updater bridge, installer daemon, or second download queue.

Rejected: separate Brew and DMG installers create two mutation paths. A custom downloader/installer duplicates Sparkle's trusted replacement path. A completely custom user driver adds unnecessary confirmation and progress UI.

## User experience

| State | Notification and dropdown | Action |
| --- | --- | --- |
| Idle | Installed version and **Check for Updates…**. **Download Latest Update…** stays visible but disabled until an update is offered. **Automatically Install Updates** is off initially | Manual checking works without enabling automatic installation |
| Checking | **Checking for updates…** | Disable duplicate checks |
| Current | Explicit checks show **You're up to date** | Scheduled checks stay quiet |
| Available | **PersonaStack VERSION is available**. Toast: **Download Update…**, **Later**. Dropdown: **Download Latest Update…** | Open the standard version/release-notes confirmation. Download starts after confirmation |
| Automatic install needs attention | Version-specific status and **Continue Update…**. Information-only updates show **View Update Information…** | Reopen Sparkle's current session so the user can authorize or continue the scheduled update |
| Downloading/preparing | Standard progress and applicable cancellation. Dropdown shows the current operation | Continue using PersonaStack. Cancellation keeps the installed version |
| Ready | **Version VERSION is ready. Restart PersonaStack to finish updating.** Toast and dropdown offer **Restart Now** and **Later** | Restart Now explicitly confirms restart. Later dismisses the reminder. Normal quit installs without reopening the app |
| Updated | **Updated to VERSION** on the next launch | Resume the existing signed-in environment |
| Error/permission needed | Specific safe error or **Installation needs your approval** | Retry or open the standard authorization flow. Keep the working app |

The automatic setting explains: **Download updates in the background. Install when PersonaStack quits.** Enabling it permits unattended downloading and preparation. It never permits a forced restart. Disabling it affects future automatic updates. A prepared update remains ready until installed or explicitly canceled through the updater.

Checks run approximately every 24 hours while the process is running, including when normal windows are closed. Sparkle checks after an overdue launch. The fully quit app does not wake itself. Once an update is prepared, Sparkle resumes that pending installation rather than fetching another release. **Check for Updates…** then shows the ready update. This pending exception is deliberate. Daily discovery of newer releases while another update is prepared would require another polling or cancellation path. [Schedule settings](https://sparkle-project.org/documentation/customization/), [pending-update source](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUpdater.m#L487-L505)

Show a native toast in a visible PersonaStack window. Use a macOS notification banner when the app is in the background. Keep dropdown status when notifications are denied. Scheduled checks do not steal focus. Deduplicate available and ready reminders by version and state. **Later** does not skip a release or turn off automatic updates. Explicit checking can bring the current update UI back. [Gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/)

Restart confirmation explains that windows close and active Desktop Control tasks stop. An update does not preserve in-memory tasks or unsent drafts. Restore the main window after a foreground update restart. Normal background startup retains its current behavior. Existing chat and stack popout restoration is outside scope.

## Phase 1: Package a trusted updater and release description

Journey: both installation methods receive a bundle that can authenticate the next release.

Owners: `Package.swift`, `Resources/Info.plist`, `scripts/package-macos.sh`, `scripts/render-homebrew-cask.sh`, `.github/workflows/release.yml`, and tap cask/feed documentation.

- [x] Pin Sparkle at 2.10.0 in `Package.swift` and `Package.resolved`.
- [x] Embed its universal framework and required helpers with correct runtime search paths, symlinks, executable permissions, and nested signing treatment. Both architecture builds were combined into a disposable app bundle with the Sparkle framework. The bundle verifier passed. A temporary DMG payload containing the app, Applications link, and background was mounted and inspected. The Finder arrangement script compiled but was not run.
- [x] Write stable numeric versions into `CFBundleVersion` and `CFBundleShortVersionString`. Reject prerelease tags in packaging and cask rendering.
- [x] Configure the fixed HTTPS tap feed, signed-feed validation, pre-extraction verification, non-expiring signature failures, disabled system profiling, and disabled release-note JavaScript. Release packaging injects the public key. Archive verification remains Sparkle-owned.
- [x] Add release source that generates cask and appcast metadata from the same DMG. The cask enables `auto_updates true` and consumes only the current version's exact DMG path. The tap artifact/tag is pushed before the signed appcast. The workflow checks that configured public and private Ed25519 keys match, verifies the DMG and appcast signatures with Sparkle's `sign_update`, and checks release version, exact immutable URL, inline notes, DMG length, and cask SHA-256. It reads Sparkle's `<sparkle:version>` item and pairs release notes with the archive filename. The release-notes lookup targets `personastack/macos-desktop` explicitly.
- [x] Add native update-policy tests, appcast validator fixtures for trusted and untrusted archive URLs, and a bundle verifier. Update native `SPEC.md`, README, and tap documentation.
- [ ] Run Sparkle archive/feed signing with the configured release keys. A disposable app and throwaway Ed25519 key generated a feed with embedded release notes and both archive/feed signatures verified. The public key, private key, and Homebrew token are not configured in this environment. The universal bundle verifier has passed separately.

EdDSA archive authentication can support unsigned applications. It does not provide Gatekeeper notarization or stable OS permission identity. Preserve the public bundle's effective signing mode across updates. Sparkle rejects an update that removes an existing code signature. Key custody and nested packaging need special attention in the current unsigned release pipeline. [Sparkle setup](https://sparkle-project.org/documentation/), [validator source](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SUUpdateValidator.m)

## Phase 2: Discover updates and let the user confirm a download

Journey: a user receives a daily reminder or checks manually, then chooses whether to download.

Owners: `PersonaStackApp.swift`, `DesktopControlMenu.swift`, and the new native updater coordinator/adapter.

- [x] Initialize one app-lifetime updater after app launch. Default automatic checks on with a 24-hour interval. Default automatic downloads off. Bind the menu setting directly to Sparkle's persisted preference.
- [x] Add an Updates section to the menu-bar dropdown and a conventional app-menu check action. Show installed/offered versions and checking/available status. Keep **Check for Updates…** and **Download Latest Update…** visible. Both actions use the same Sparkle session.
- [x] Show checking, download, extraction, and ready state in the dropdown. Scheduled updates that Sparkle downloads automatically show a background-download status and do not expose an unusable download action. Disable repeated checks during an active check, automatic download, or ready update. Sparkle continues to own its standard progress window.
- [x] Implement once-per-version scheduled reminders and native available/ready/update-complete toasts. The Sparkle reminder delegate suppresses its scheduled alert until the user chooses a reminder. Check and download actions refocus the current Sparkle session. Ready transitions preserve deduplication and do not clear or revive an existing ready reminder. A single app-lifetime `UNUserNotificationCenter` delegate owns concern and update notifications. Notification actions open the same download/restart paths. Concern handling remains attached to the persistent WebView coordinator when windows close or Server Settings replace the host. Dropdown actions remain usable when notifications are denied.
- [x] Add in-process Swift tests with an injected updater facade for configured feed validation, preference delegation, manual versus scheduled outcomes, duplicate reminders, ready Later/Restart Now choices, repeated-check suppression, automatic-ready deferral, one-shot restart handling, termination version persistence, and read-only install guidance. Policy tests cover feed/version rules, Sparkle outcomes, ready deduplication, and read-only/translocated bundle detection. Read-only startup verifies Sparkle is not started and the saved automatic-download preference is preserved. Terminal install failure verifies matching restart metadata is cleared.
- [x] Handle Sparkle's download-cancel callback by clearing stale progress and keeping a manual offer retryable. Focused tests cover cancellation projection, terminal error teardown, and preservation of the ready state for Sparkle's benign no-update result. Sparkle retains its built-in progress and error presentation.

No hosted web, API, OAuth, gateway protocol, or product-state changes are required.

## Phase 3: Prepare the update and restart without logging out

Journey: manual and automatic downloads reach the same ready state. Later and ordinary quit work. Restart Now returns to PersonaStack.

Owners: native adapter/coordinator, `PersonaStackTerminationDelegate`, and existing main-window startup logic.

- [x] Intercept manual `showReadyToInstallAndRelaunch` with a native ready alert. **Later** returns `.dismiss`; **Restart Now** returns `.install`. If the user later restarts from the menu, refocus the existing Sparkle confirmation so its `.install` choice relaunches the app. The installing-stage callback records foreground restart intent when the user accepts this resumed install. Sparkle retains the prepared installer.
- [x] Project automatically prepared updates into the ready state with version-scoped reminders. **Restart Now** invokes Sparkle's retained immediate-install handler so Sparkle installs and relaunches. Ordinary app termination still installs a prepared update on quit. Persist the expected target version for both explicit restart and normal quit. Show success only when that version launches; clear a stale target without reporting success.
- [x] Route update restarts through the existing app termination delegate so Desktop Control shuts down within its bounded timeout. Record explicit foreground restart intent and restore the main window after relaunch. A foreground update relaunch still starts the saved Desktop Control relay while retaining regular app activation. Installed-app behavior still needs acceptance.
- [x] Preserve `ai.personastack.desktop`, `WKWebsiteDataStore.default()`, selected server settings, Keychain credential services, user preferences, and user data. The updater replaces only the app bundle and stores no session tokens. Existing data and Desktop Control reconnect through ordinary startup. Installed session continuity still needs acceptance.
- [x] Test manual ready Later and Restart Now choices and their restart callback. Record the no-logout acceptance requirement in `SPEC.md`.
- [x] Test automatic ready projection, Later deferral, Restart Now confirmation, single immediate-handler consumption, normal-quit version persistence, terminal error teardown, preservation of the retained installer after a benign Sparkle no-update result, manual download cancellation state, background automatic-download status, authorization fallback across Sparkle's not-downloaded/downloaded/installing stages, informational updates, skipped offer and prepared-update cleanup, resumed-install foreground intent, and foreground relaunch activation policy.
- [x] Test stale restart intent through app startup. The matching target reports success; a mismatched target clears without claiming success.
- [x] Test that update notification routing ignores concern notifications, that the concern receiver survives window close/reopen, and that Desktop Control shutdown replies at its bounded deadline.

The public ready contract permits deferred installation after ordinary termination. Resuming an existing installer supplies the `Installing` stage needed for Restart Now. [User-driver contract](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html), [resume dispatch](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUpdater.m#L857-L874), [installing-stage response](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUIBasedUpdateDriver.m#L249-L295)

The native app already uses a persistent WebKit store. The hosted session cookie has an expiry. Keep those existing mechanisms. A restart must preserve a valid session. Expired or revoked sessions still follow normal server authentication policy.

## Phase 4: Prove the installed update journeys

All acceptance remains unchecked until performed on installed macOS bundles. Use disposable installation fixtures and low CPU priority for packaging. No live publication, release tag, or production activation is authorized by this plan.

- [ ] Exercise an old-to-new bundle pair from Homebrew and from a dragged DMG install. Cover manual confirmation, automatic opt-in, continued use while downloading, ready toast, Later, ordinary quit without relaunch, next launch on the new version, and Restart Now with exactly one relaunch.
- [ ] Verify the signed-in account/workspace and saved server environment after restart. Verify the enrolled Desktop Control credential, paused state, notification behavior, and OS permission status. Test normal window closure and menu-only/background operation. Record actual installed-version and visible-screen evidence.
- [ ] Exercise offline checks, canceled download/authorization, corrupt or wrong-key archive/feed, unsupported OS, read-only DMG/translocation, and nonwritable/custom installation locations. The source-level read-only path now skips Sparkle and is covered by focused tests; this installed run must confirm that packaged read-only and translocated copies perform no update work and show the Applications instruction. Failed updates must retain a usable installed app.
- [ ] Verify Homebrew's version/readback and routine upgrade behavior after an app-driven update. Confirm cask and website installations receive identical updater configuration. Document one-time bootstrap installation for clients without an updater and signing/notification limitations. Close only after the two installation journeys pass.

## Material limits

- Current releases contain no updater. Users must install the first updater-enabled version through Homebrew or the normal DMG flow once.
- Another owner's application bundle may require macOS authorization. Automatic mode can prepare a download but cannot promise silent installation through an authorization requirement.
- Loss of the Ed25519 key can require manual recovery, particularly without Developer ID signing. Provision protected release storage and a backup before activation.
- Gatekeeper, native Keychain access, and OS permissions across updates require real installed-Mac evidence with the chosen signing mode. Developer ID/notarization improves distribution but is a separately scoped change.
- App replacement does not promise draft recovery, active task replay, popout restoration, automatic downgrade, or crash recovery. Failed-update handling remains Sparkle-owned.

## Completion gate

- [x] Targeted validation is green: current source builds in release mode for arm64 and x86_64 at low CPU priority against the cached Sparkle framework. A fresh disposable universal app bundle passes the verifier. Thirty-one focused tests pass across four suites, including read-only installation guidance, updater, reminder-policy, notification, concern-window, and bounded-shutdown cases. Both appcast fixture tests previously passed. Sparkle generated and verified a signed feed/archive with a disposable key. A temporary DMG payload was inspected, the Finder layout AppleScript compiled, and release workflow YAML, packaging scripts, plist, and Swift sources parse.
- [x] Required source-level regression coverage is complete: 31 focused Swift tests cover updater, policy, notification, concern-window, bounded-shutdown, read-only startup, saved preference preservation, failure restart-metadata cleanup, and menu guidance. Two appcast fixture tests pass. Coverage includes cancellation state, automatic authorization fallback across all Sparkle stages, information-only updates, skipped prepared offers, and Sparkle-owned presentation. Normal package manifest resolution and the broader pre-existing suite remain separate environment/scope gaps.
- [x] Local review is clean: reviewed the final updater, policy, notification, app lifecycle, packaging, feed-validation, and workflow diffs. The gaslight pass found no remaining significant source or plan-alignment issue.
- [x] Independent review is clean: fresh full-surface review of the read-only startup, preference preservation, failure cleanup, normal update flows, menu state, tests, docs, and package verifier found no significant findings. It confirmed read-only/translocated startup returns before creating Sparkle and that benign no-update handling retains the prepared installer.
- [x] `$logic-patterns:adversary-loop` is clean after the read-only startup and failure-cleanup changes. The full-surface review ledger shrank from the Sparkle quit-install and stale foreground-relaunch findings to no significant findings.
- [x] Source build and bundle checks are green: release builds passed for arm64 and x86_64 against the cached Sparkle framework. The disposable universal bundle passed its verifier. Appcast fixtures and disposable-key feed/archive signing checks passed.
- [ ] Installed acceptance remains unverified: Finder window arrangement, configured release-key checks, and the Homebrew and DMG old-to-new update journeys need an installed-Mac run. Do not enter OS passwords or accept security prompts. No release was published.
- [x] Tracker is not used for this plan; no linked tracker issue is required.
