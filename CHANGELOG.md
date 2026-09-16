# Changelog

All notable changes follow semantic versioning.

## [0.1.2] - 2026-09-15

### Fixed

- Discover architecture-specific Swift build products so the installer builds on both local and GitHub macOS toolchains.

## [0.1.1] - 2026-09-15

### Fixed

- Build the application icon from a source asset bundled in this repository so release runners can package the installer from a clean checkout.

## [0.1.0] - 2026-09-15

### Added

- Native macOS PersonaStack window backed by persistent WebKit website data.
- Existing `my.personastack.ai` authentication, OAuth redirects, uploads, downloads, and realtime behavior.
- PersonaStack application icon generated from the repository-owned `art/personastack-512.png` asset.
- Unsigned DMG packaging script and tag-triggered GitHub release workflow.
