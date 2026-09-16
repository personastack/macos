# Architecture decisions

- 2026-09-15: The macOS client is a thin native SwiftUI and WebKit shell for the existing `my.personastack.ai` website. It does not add a second authentication, API, datastore, or product-state authority. The first release is unsigned and distributed as a GitHub Release disk image.
