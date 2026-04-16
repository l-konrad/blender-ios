# Blender iOS Port

Documentation for the iOS / iPadOS fork of Blender maintained in this
repository.

## Contents

- [architecture.md](architecture.md) — High-level architecture of the iOS
  backend, the `WITH_APPLE_CROSSPLATFORM` switch, and the WM↔GHOST bridge.
- [feature_matrix.md](feature_matrix.md) — Which Blender features and
  dependencies are enabled on iOS vs. macOS/Linux/Windows.
- [known_issues.md](known_issues.md) — Tracked issues replacing the legacy
  `IOS_FIXME` comment markers in source code.
- [rebase_workflow.md](rebase_workflow.md) — How to rebase this fork onto
  upstream `blender/main` with minimum pain.
- [proposals.md](proposals.md) — Accepted architectural proposals that are
  not yet implemented, with design sketches.

## Building

See [setup_ios.sh](../../setup_ios.sh) for the bootstrap script.
