<div align="center">

<img src="Resources/AppIcon-source.png" alt="PersonaStack app icon" width="72">

<h1>PersonaStack for macOS</h1>

<p>Your PersonaStack workspace in a native macOS app.</p>

<p>
<a href="https://github.com/personastack/homebrew-tap"><img src="https://img.shields.io/badge/Homebrew-cask-FBB040?logo=homebrew&logoColor=black" alt="Homebrew cask"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-20232A?logo=apple&logoColor=white" alt="macOS 14 or later">
</p>

<p><a href="https://personastack.ai">Website</a> · <a href="https://github.com/personastack/macos/releases/latest">Latest download</a></p>

<img src="docs/desktop-app.png" alt="PersonaStack sign-in screen in the macOS app" width="1000">

</div>

## Install with Homebrew

Copy and paste this command into Terminal:

```sh
brew install --cask personastack/tap/personastack
```

Open PersonaStack from Applications and sign in. Requires macOS 14 or later.

The build uses the pinned Developer ID Application certificate for PersonaStack, LLC (team `5T2T8KL852`). The app and Sparkle helpers use hardened runtime and secure timestamps. Release builds are notarized by Apple. Both the app and installer carry stapled notarization tickets.

After moving from an unsigned or self-signed build to Developer ID signing, macOS may require permission approval again. For Accessibility, remove the old PersonaStack entry in Privacy & Security and add PersonaStack.app from Applications. For Screen Recording and Microphone, turn PersonaStack off and on. Relaunch if macOS requests it, then retry the Setup buttons.

### Check installed-app permissions

Use **Desktop Control → Diagnostics…** for the running app's permission state. To collect a read-only preflight from a separate macOS-launched app process:

```sh
open -n -W -a /Applications/PersonaStack.app \
  --stdout /tmp/personastack-permissions.txt \
  --stderr /tmp/personastack-permissions-errors.txt \
  --args --personastack-permission-diagnostics
cat /tmp/personastack-permissions.txt
```

Launching `Contents/MacOS/PersonaStack` directly from Terminal can use Terminal's responsible-app permissions. That result does not prove PersonaStack has its own grants. Preflight also does not prove actual capture or input. Complete those checks through the app's permissions checklist.

## Updates

PersonaStack checks for updates while it is running. Open the menu-bar dropdown or the **PersonaStack** menu and choose **Check for Updates…** to check now. You can opt into background downloads in the menu-bar dropdown. Prepared updates install when you quit PersonaStack. The app does not restart without your action.

## Unattended Desktop Control implementation

The current source includes one main installation package, a lease-scoped supervisor, nested diagnostics, controller activity, bounded recovery and WebView Retry. Full control remains one on/off choice. The locked-session component still needs dedicated-Mac physical qualification. The signed main package installs the authorization plug-in and policy. Unsigned local packages install only the app.

`PersonaStackLockedControlInstaller` is our one-shot policy writer. The main `Install PersonaStack.pkg` installs it and the signed plug-in together with the app. Set Up Desktop Control verifies this installation and records acknowledgement. It never opens a separate locked-control installer. `scripts/package-desktop-installer.sh APP COMPILED_INSTALLER OUTPUT_PKG` builds the main package without installing it. `scripts/package-locked-control.sh` builds its internal signed component. Release packaging requires `PERSONASTACK_INSTALLER_SIGNING_IDENTITY` for a Developer ID Installer signature in addition to the existing Developer ID Application identity. Public distribution remains subject to the repository's notarization gates. Sparkle and Homebrew run the same main package. Package updates require administrator approval. Homebrew uninstall first removes the verified PersonaStack policy branch.

For unsigned local builds, set `PERSONASTACK_INCLUDE_LOCKED_CONTROL=0` when building the main package. This packages only the app. Locked-screen control requires the pinned Developer ID signatures and is unavailable in an unsigned build. No release signing credentials are used for local packaging.

The installer uses Apple's `AuthorizationRightGet` and `AuthorizationRightSet` APIs. The policy schema and actual locked-session flow still require OS-build qualification. See `Experiments/LockedSessionCandidate/README.md` and the unattended-control plan for the unrun physical gates. Do not run the package on the working development Mac as a substitute for that evidence.
