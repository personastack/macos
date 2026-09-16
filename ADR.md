# Architecture decisions

- 2026-09-15: The macOS client is a thin native SwiftUI and WebKit shell for the existing `my.personastack.ai` website. It does not add a second authentication, API, datastore, or product-state authority. The first release is unsigned and distributed as a GitHub Release disk image.
- 2026-09-15: The macOS client accepts one main-frame `my.personastack.ai` WebKit bridge event for new concerns. The event is schema-checked and carries no concern or account data. The client owns only generic notification presentation while it is running.
- 2026-09-15: The desktop source and primary GitHub release remain private. Every tagged installer is also published to the public `personastack/homebrew-tap` release, which owns the Homebrew cask and its public immutable download URL.
