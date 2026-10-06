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

## Desktop Control with CUA

Choose **Desktop Control → Set Up CUA…** in PersonaStack. Click **Install CUA** to download and install the verified official Cua Driver app. A compatible existing installation is reused. Complete CUA's own macOS permission prompts, then check the connection and connect PersonaStack.

CUA controls this Mac. PersonaStack connects your authorized agents to CUA. CUA has its own login service and remains installed after PersonaStack is removed. Cloud control through PersonaStack still requires PersonaStack to run. The menu shows CUA readiness separately from the cloud connection.

PersonaStack no longer asks for desktop Accessibility, Screen Recording, Full Disk Access, or browser Automation permissions. Chat microphone and notification permissions remain separate. CUA must receive its own grants. Old PersonaStack grants are not transferred or reset automatically.

Native remote filesystem/shell tools and PersonaStack's locked-screen helper are retired. CUA's actual capabilities and local policy govern available actions. Running a service does not guarantee locked-screen or closed-lid GUI control.

## Updates

PersonaStack checks for updates while it is running. Open the menu-bar dropdown or the **PersonaStack** menu and choose **Check for Updates…** to check now. You can opt into background downloads in the menu-bar dropdown. Prepared updates install when you quit PersonaStack. The app does not restart without your action.

## Installer packaging

The main package installs PersonaStack.app only. `scripts/package-desktop-installer.sh APP OUTPUT_PKG` builds it without installing it. For unsigned local validation, set `PERSONASTACK_SIGN_INSTALLER=0`. Release packaging retains Developer ID signing, notarization, and Sparkle verification.

New packages do not install the old locked-control plugin. During upgrade, the package verifies the existing removal utility against the pinned signing certificate and runs its guarded policy restoration before removing the retired plugin and utility. A missing utility, invalid signature, or policy conflict stops the upgrade without deleting the legacy payload. Fresh installs skip this step. Homebrew uninstall also guards legacy cleanup and never removes standalone CUA.
