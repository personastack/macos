# macOS update feed operations

The application reads the signed Sparkle feed at `https://raw.githubusercontent.com/personastack/homebrew-tap/main/appcast.xml`. Release assets remain immutable and are hosted by the versioned `desktop-vVERSION` tag in `personastack/homebrew-tap`.

Before the first updater-enabled tag, configure these GitHub values in `personastack/macos-desktop`:

- Repository variable `PERSONASTACK_SPARKLE_PUBLIC_ED_KEY`: base64 Ed25519 public key, exactly 32 decoded bytes.
- Repository secret `PERSONASTACK_SPARKLE_PRIVATE_ED_KEY`: matching Sparkle private key in the format accepted by Sparkle's `generate_appcast --ed-key-file -`.
- Repository secret `HOMEBREW_TAP_TOKEN`: write access to `personastack/homebrew-tap`.

Generate the signing key through Sparkle's official `generate_keys` tool. It saves the private key in the operator's login Keychain and prints the public key. Export the private key with `generate_keys -x <private-key-file>` and store the exported value in GitHub's repository secret. Exporting and using the key can trigger macOS Keychain authorization. An authorized release maintainer must complete that step and keep a protected backup before release activation. Do not commit or print the private key. The release workflow sends it to `generate_appcast` through standard input. It verifies the published framework and tool archive checksum before use. See Sparkle's [key setup and export guidance](https://sparkle-project.org/documentation/).

Before building, the workflow derives the public key from the private-key secret and fails if it does not match the repository variable. It never prints the private key. The workflow publishes in this order:

1. Build one universal DMG with the public key, release version, and embedded Sparkle framework.
2. Create the app release and publish the same DMG to the versioned tap tag. The generated cask enables `auto_updates true` and records that DMG's SHA-256.
3. Generate the signed feed using only the current updater-enabled DMG and the prior signed feed. This avoids importing older pre-Sparkle DMGs from `Downloads/`.
4. Verify the feed and archive signatures with Sparkle's `sign_update --verify`, then check the exact version, length, inline release notes, and immutable tap URL before publishing the new feed on `main`.

If release automation stops after creating the versioned tap tag, do not reuse or overwrite that tag. Inspect the immutable DMG and repair the feed publication as a separate change. A retry with an existing app release or tap tag intentionally fails instead of replacing its artifact.

The first updater-enabled release is a bootstrap update. Existing app versions without Sparkle cannot read the feed; users must update once through Homebrew or the DMG. macOS authorization or file ownership can still require user approval during app replacement.

When PersonaStack runs from a read-only disk image or an App Translocation path, PersonaStack does not initialize Sparkle. It performs no update checks, downloads, or install-on-quit attempts. The menu explains that updates require a copy in Applications. The existing automatic-download preference stays saved and resumes when the Applications copy opens.
