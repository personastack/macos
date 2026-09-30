<div align="center">

<img src="Resources/AppIcon-source.png" alt="PersonaStack app icon" width="72">

<h1>PersonaStack for macOS</h1>

<p>Your PersonaStack workspace in a native macOS app.</p>

<p>
<a href="https://github.com/personastack/homebrew-tap"><img src="https://img.shields.io/badge/Homebrew-cask-FBB040?logo=homebrew&logoColor=black" alt="Homebrew cask"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-20232A?logo=apple&logoColor=white" alt="macOS 14 or later">
</p>

<p><a href="https://personastack.ai">Website</a> · <a href="https://github.com/personastack/macos-desktop/releases/latest">Latest download</a></p>

<img src="docs/desktop-app.png" alt="PersonaStack sign-in screen in the macOS app" width="1000">

</div>

## Install with Homebrew

Copy and paste this command into Terminal:

```sh
brew install --cask personastack/tap/personastack
```

Open PersonaStack from Applications and sign in. Requires macOS 14 or later.

The app uses a persistent self-signed certificate. It is not Developer ID signed or notarized. If macOS blocks its first launch, choose **Open Anyway** in **System Settings → Privacy & Security**.

After updating from an unsigned build, reapprove permissions once. For Accessibility, remove the old PersonaStack entry in Privacy & Security and add PersonaStack.app from Applications. For Screen Recording and Microphone, turn PersonaStack off and on. Relaunch if macOS requests it, then retry the Setup buttons.

## Updates

PersonaStack checks for updates while it is running. Open the menu-bar dropdown or the **PersonaStack** menu and choose **Check for Updates…** to check now. You can opt into background downloads in the menu-bar dropdown. Prepared updates install when you quit PersonaStack. The app does not restart without your action.
