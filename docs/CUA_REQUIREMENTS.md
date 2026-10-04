# Cua requirements on macOS

This inventory covers PersonaStack's embedded **Cua Driver 0.29.1**, schema 1, at upstream commit `7a8f66ad04e62fccb18cca9965f2964fcaee124e`. Reaudit this inventory when changing the pinned driver or `CuaDriverCompatibility.exposedTools`.

## Permissions and setup

| Requirement | Used by | PersonaStack integration |
| --- | --- | --- |
| Accessibility and event-synthesis access | AX observation, element and pointer input, menus, windows and application control | Existing Accessibility row. Shared native trust/role/event-post preflight. This remains the only OS grant that gates ordinary enrollment. |
| Screen Recording | Screenshot and desktop/window observation | Existing Screen Capture row. Reads the host grant separately from Accessibility. |
| ScreenCaptureKit direct capture approval | Screenshots without the private window picker. macOS may show an additional dialog after Screen Recording was allowed. | Direct Capture row. Explicit Setup captures a 1-pixel host image and discards it. Opening the checklist, polling and Check never capture or prompt. The actual owned driver still verifies its own capture at command admission. |
| Target-specific Apple Events approval | Exposed `set_value` fallback for Safari HTML select controls | Application Automation row. Non-prompting `AEDeterminePermissionToAutomateTarget` checks Safari. Only Setup requests consent. Denial opens Automation settings. No global or mission-level grant exists. Other apps remain separately authorized. |
| Safari “Allow JavaScript from Apple Events” | The same Safari `set_value` fallback | Safari JavaScript row. Setup opens Safari and shows the Advanced → developer features → Developer → Automation steps. Check requires a running Safari process and existing Automation approval. It evaluates the fixed constant `1` in an open tab. No page content is read or changed. Proof is scoped to the Safari process and invalidated on failure or observed Automation revocation. After changing Safari's setting, choose Check again. |
| Clipboard / Pasteboard privacy | Exposed Cua clipboard tools | Clipboard row reads only NSPasteboard.accessBehavior on macOS 15.4+. Only explicit Setup attempts a text read to register macOS consent and discards the data. Only Always Allow marks unattended access Ready. Ask, default and denial show recovery instructions. The row is hidden on older systems. |
| Host Apple Events purpose and hardened-runtime entitlement | Attribution of Safari Automation consent to PersonaStack | `NSAppleEventsUsageDescription` in `Resources/Info.plist`. `com.apple.security.automation.apple-events` in `Resources/Release.entitlements`. Signing applies the main app's entitlements through the existing packaging path. |
| Logged-in user, awake Mac, active session and supported local OS | All GUI operations | Existing runtime/session gates. PersonaStack requires macOS 14+. Locked control uses its separate installed supervisor, user authorization and takeover gates. |
| Signed, compatible embedded driver | All Cua operations | Existing installer pins version, schema, archive and executable checksums, bundle/team identity and required tools. The owned daemon uses host attribution and its private socket. Diagnostics and runtime repair retain their existing owners. |
| Installed supported Chromium browser and approved profile strategy | First-class browser tools | Existing `browser_prepare` selects verified system Chrome/Edge and an isolated new profile. PersonaStack prevents caller-selected existing profiles, executables and permission modes. Missing browser or unsupported route returns the existing setup guidance. No new OS grant is required. |

Direct Capture, Automation, Safari JavaScript and Clipboard are feature-specific optional rows. Their denial does not remove working Accessibility-only input. Each uses the existing row status, Check/Setup buttons, progress, cancellation and Settings recovery patterns. None resets existing OS grants. The host's Screen Capture reset also invalidates Direct Capture proof.

## Requirements outside the exposed Cua surface

| Capability | Scope and integration |
| --- | --- |
| Full Disk Access and filesystem permissions | PersonaStack's native file and process executors own these. The existing Full Disk Access row performs its bounded protected-folder check. It does not override ownership, ACLs, SIP or network-share credentials. |
| Microphone | PersonaStack chat voice messages use the existing Microphone row and WebKit verification. Cua GUI control does not require it. |
| Local Network | Existing Local Network row checks selected LAN service endpoints when applicable. Cloud selection and older macOS hide this row. Cua's owned local socket does not create a LAN listener. |
| Notifications, Launch at Login, automatic updates and sleep prevention | Existing automatic settings rows. These support the host's lifecycle and are separate from Cua's OS grants. |
| Camera, speech recognition and system audio | Not used by the reviewed Cua tool surface. ScreenCaptureKit checks explicitly disable audio. No grant is requested. |
| Input Monitoring | Ordinary input synthesis uses Accessibility. PersonaStack's locked-control takeover listener uses an active event filter under its Accessibility/session gates. It does not install Cua's separate read-only input-monitoring capability. No extra Input Monitoring grant is requested. |
| Safari Remote Automation / WebDriver | The exposed first-class Safari DOM route is unsupported. Its returned guidance uses GUI control or isolated Chrome/Edge. “Allow remote automation” does not enable the Safari Apple Events select fallback. |
| Chrome/Brave/Edge JavaScript from Apple Events | Upstream BrowserJS page tools can require these browser settings and their individual Automation grants. Those page tools are absent from `exposedTools`. PersonaStack's first-class Chromium tools use the approved CDP profile route instead. Do not request unused browser grants. |
| Existing-profile consent and remote-debugging connection prompt | Upstream supports additional profile strategies. PersonaStack only prepares isolated profiles and rejects existing-profile selection. These upstream consent modes do not justify granting access to the user's personal browser profile during setup. |

## Source evidence

- [Pinned macOS permissions reference](https://github.com/trycua/cua/blob/7a8f66ad04e62fccb18cca9965f2964fcaee124e/docs/content/docs/reference/cua-driver/macos-permissions.mdx)
- [Pinned Safari select fallback](https://github.com/trycua/cua/blob/7a8f66ad04e62fccb18cca9965f2964fcaee124e/libs/cua-driver/rust/crates/platform-macos/src/tools/set_value.rs)
- [Pinned BrowserJS targets](https://github.com/trycua/cua/blob/7a8f66ad04e62fccb18cca9965f2964fcaee124e/libs/cua-driver/rust/crates/platform-macos/src/browser/browser_js.rs)
- [Pinned driver entitlements](https://github.com/trycua/cua/blob/7a8f66ad04e62fccb18cca9965f2964fcaee124e/libs/cua-driver/rust/scripts/CuaDriver.entitlements)
- [Apple Automation controls](https://support.apple.com/en-hk/guide/mac-help/mchl108e1718/mac)
- [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
- [AppKit pasteboard privacy](https://developer.apple.com/documentation/updates/appkit#macOS-pasteboard-privacy)
- [Pasteboard access policy](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
- [Safari Developer settings](https://developer.apple.com/documentation/safari-developer-tools/developer-settings)

## Validation boundary

In-process Swift fixtures cover row selection, non-prompting reads, explicit setup, canonical readback, denial, missing targets, capture proof, revoked grants, process changes, cancelled late replies and packaged declarations. They do not grant real TCC permissions. Signed installed-app attribution, the real macOS dialog sequence and notarization remain packaged-app acceptance checks.

### Local validation

The focused suite passed **116 tests** in 3.4 seconds on 2026-10-03. Resource plists passed `plutil -lint`. The Command Line Tools runner needed its installed Swift Testing framework and macro plugin:

```sh
swift test --disable-xctest --skip-update -j 2 \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  --filter '(DesktopPermission|DesktopSupplemental|packagedHostDeclares)'
```

Hidden native-window previews used fake permission observations at 670×740, 560×460 and 800×600. These show text wrapping and the fixed footer. Offscreen AppKit drawing omits native button labels, so the previews do not establish button contrast or live interaction behavior. Source review corrected Safari's recovery label to “Open Safari”, added permission-specific accessibility labels and reused the existing optional-setup caption for the four new rows. Signed-app visual and real-dialog checks remain unrun.

The audit read the workspace architecture authority. This change stays within native OS permission ownership. No architecture, API, MCP or gateway contract changed.
