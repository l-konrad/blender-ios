# iOS Architectural Proposals

Accepted design proposals produced from the architectural review of the
iOS fork. Items marked **landed** have been implemented; others are
design-only and tracked here until someone with an iOS build environment
picks them up.

---

## P1 — Collapse `WITH_APPLE_CROSSPLATFORM` into a layered feature model

**Status:** design only — blocked on iOS build verification.

`WITH_APPLE_CROSSPLATFORM` is currently used as a grab-bag for every
difference between iOS and macOS: missing dependencies, sandbox
restrictions, platform behavior, temporary stubs. 235 occurrences across
103 files.

### Proposal

Replace with **three orthogonal axes**:

```
GHOST_PLATFORM_IOS                      (platform identity)
WITH_BLENDER_FEATURE_USD / _CERES / …   (feature availability; reuse existing flags)
BLI_SANDBOXED_FILESYSTEM                (sandbox behavior; also applies to macOS App Store build)
```

A guard like:

```cpp
#ifdef WITH_APPLE_CROSSPLATFORM
  /* Skip because Ceres isn't built for iOS. */
#endif
```

becomes:

```cpp
#ifndef WITH_LIBMV
  /* Skip — no motion tracker available. */
#endif
```

### Migration strategy

1. Keep `WITH_APPLE_CROSSPLATFORM` as an alias that sets the three axes.
2. Sweep the codebase one subsystem at a time (Cycles, GPU, WM, editors,
   creator), replacing guards with the semantically correct axis.
3. When every occurrence is migrated, remove `WITH_APPLE_CROSSPLATFORM`
   entirely and rename the build option to `WITH_APPLE_IOS`.

### Why not land now

Every guard touches a platform that cannot be exercised in CI on the
fork's current infrastructure. Changing them blind risks breaking the
iOS build in ways no one notices for weeks. Land after [P8](#p8) CI is
live.

---

## P2 — Introduce `GHOST_AppleBase` shared superclass

**Status:** design only.

`GHOST_SystemIOS.mm` (841 lines) and `GHOST_SystemCocoa.mm` share a
substantial amount of logic: `@autoreleasepool` management, pasteboard,
timer creation, display DPI queries, HDR/EDR capability detection, clip
board monitoring. Same for `GHOST_WindowIOS.mm` (1,918 lines) vs
`GHOST_WindowCocoa.mm`.

### Proposal

New files in `intern/ghost/intern/`:

- `GHOST_SystemApple.hh` / `.mm` — non-abstract base with shared
  implementations.
- `GHOST_WindowApple.hh` / `.mm` — same for windows.

`GHOST_SystemCocoa` and `GHOST_SystemIOS` inherit from
`GHOST_SystemApple`; the latter just overrides UIKit-specific methods.
Expected reduction: ~1,500–2,000 LOC of duplication.

Prerequisite: a macOS contributor willing to review the Cocoa side of
the refactor, since it touches code that currently works and the iOS
fork has no authority over it.

---

## P3 — Split `GHOST_C-api` into core + iOS surfaces

**Status:** design only.

`GHOST_C-api.cc` grew by 1,337 LOC with iOS-specific entry points:
`GHOST_popupOnScreenKeyboard`, `GHOST_openFilePicker`, touch event
helpers, keyboard visibility queries. These are declared in the
cross-platform header `GHOST_C-api.h`, leaking iOS-only symbols into
builds for every other backend.

### Proposal

1. Create `intern/ghost/GHOST_C-api_ios.h` guarded with
   `#ifdef WITH_APPLE_CROSSPLATFORM`.
2. Move iOS-only prototypes from `GHOST_C-api.h` into it.
3. Create `intern/ghost/intern/GHOST_C-api_ios.cc` for the
   implementations; compile only when `APPLE_TARGET_IOS`.
4. Callers in the WM / editors `#include "GHOST_C-api_ios.h"` from
   within their existing `#ifdef WITH_APPLE_CROSSPLATFORM` blocks.

Mechanical move; no logic changes. Safe to do behind the iOS CI added
by [P8](#p8).

---

## P4 — Formal `GHOST_HostCallbacks` interface

**Status:** design only (current `wm_ios_bridge.{h,cc}` is the prototype).

Four ad-hoc C functions (`WM_ios_autosave*`, `WM_ios_reduce_memory`)
wire GHOST→WM events. The pattern is sound but the naming (`WM_ios_…`)
bakes in the assumption that iOS is the only caller, which is false —
macOS sandboxing (for App Store builds) and Wayland session managers
could use the same hook.

### Proposal

```c
/* intern/ghost/GHOST_HostCallbacks.h */
struct GHOST_HostCallbacks {
  void *user_data;

  /* Persistence. */
  void (*autosave)(void *user_data);
  void (*autosave_timer_begin)(void *user_data);
  void (*autosave_timer_end)(void *user_data);

  /* Resource pressure. */
  void (*reduce_memory)(void *user_data);
  void (*thermal_pressure_changed)(void *user_data, int level);

  /* Lifecycle (future). */
  void (*will_enter_background)(void *user_data);
  void (*did_enter_foreground)(void *user_data);
};

/* In GHOST_ISystem: */
void setHostCallbacks(const GHOST_HostCallbacks *cb);
```

- WM registers one instance at startup.
- GHOST calls through the struct instead of calling named extern "C"
  symbols.
- Decouples GHOST from the windowmanager's C++ name mangling.
- Unit-testable with a mock struct.

### Migration

1. Add `GHOST_HostCallbacks` header (no implementation change yet).
2. WM startup code creates and registers the struct, initially
   populated with pointers to the existing `WM_ios_*` functions.
3. `GHOST_SystemIOS.mm` switches from `WM_ios_autosave(…)` to
   `hostCallbacks()->autosave(hostCallbacks()->user_data)`.
4. Rename `wm_ios_bridge` to `wm_host_bridge`; delete the iOS-specific
   symbol names.

---

## P5 — Extract inline bash from `source/creator/CMakeLists.txt`

**Status:** **landed** in this commit.

Two shell scripts were embedded inside `CMakeLists.txt` via `file(WRITE
… "…")` — `copy_bundle_data.sh` (~150 lines) and `sign_bundled_libs.sh`
(~10 lines). These are now real files:

- [release/ios/scripts/copy_bundle_data.sh](../../release/ios/scripts/copy_bundle_data.sh)
- [release/ios/scripts/sign_bundled_libs.sh](../../release/ios/scripts/sign_bundled_libs.sh)

Variables that used to be string-interpolated at CMake time
(`${CMAKE_SOURCE_DIR}`, `${BLENDER_VERSION}`, etc.) are now passed as
environment variables by `CMakeLists.txt` when invoking the script, so
the scripts are diff-able, lintable with `shellcheck`, and can be run
standalone for debugging.

---

## P6 — iOS-aware rebase workflow

**Status:** **landed** — documented in
[rebase_workflow.md](rebase_workflow.md).

---

## P7 — `IOS_FIXME` → `TODO(iOS IOS-NNN)`

**Status:** **landed** in this commit.

All 11 `IOS_FIXME` markers are now `TODO(iOS IOS-NNN)` references to
structured entries in [known_issues.md](known_issues.md).

---

## P8 — Minimal iOS CI

**Status:** **landed** in this commit.

[`.github/workflows/ios-configure.yml`](../../.github/workflows/ios-configure.yml)
runs a CMake configure against the iOS SDK on every push / PR. Catches
~60% of rebase-time breakage before it reaches a developer.

Scope is intentionally small: **configure only, no compile**. Compiling
requires the `lib/ios_arm64` submodule which is large and needs Git LFS
on CI; that's a future iteration.

---

## P9 — Contain Obj-C++ to GHOST + GPU-Metal

**Status:** design only.

`source/blender/editors/space_file/fsmenu_system.mm` introduces Obj-C++
in the editors layer (previously pure C++). This creates a second
Obj-C++ beachhead outside GHOST and forces ARC/Obj-C compile overhead on
editors code.

### Proposal

Move the `NSFileManager`-based enumeration into GHOST, exposing a
cross-platform helper:

```cpp
/* intern/ghost/GHOST_C-api.h */
int GHOST_getSystemPaths(
    GHOST_SystemPathKind kind, char ***out_paths, int *out_count);
```

`fsmenu_system.cc` (pure C++) calls that and is back to `.cc`.

---

## P10 — Feature matrix documentation

**Status:** **landed** — see [feature_matrix.md](feature_matrix.md).

---

## P11 — `MetalBackendProfile` for Cycles

**Status:** design only.

Cycles Metal code currently has inline `#ifdef WITH_APPLE_CROSSPLATFORM`
branches inside shader-compile hot paths. Every upstream refactor of
those paths conflicts. The cause is that iOS decisions (binary
archives, subgroup ops, compile parallelism, jetsam avoidance) live at
the *call site*, not behind an abstraction.

### Proposal

```cpp
/* intern/cycles/device/metal/metal_backend_profile.h */
enum class MetalBackendProfile {
  MacOS_Discrete,    /* AMD / Intel eGPU — most features on */
  MacOS_Unified,     /* Apple Silicon Mac */
  iOS_Device,        /* iPadOS / iOS — reduced caps, jetsam sensitive */
  iOS_Simulator,     /* No GPU — shader compile only */
};

struct MetalBackendPolicy {
  bool use_binary_archives;
  bool use_simd_subgroup_ops;
  int  max_parallel_compiles;
  bool pre_warm_shaders;
  /* … */
};

MetalBackendPolicy policy_for(MetalBackendProfile profile);
```

All `#ifdef` branches in `kernel.mm`, `queue.mm`, `device_impl.mm`
collapse to reads of a const `MetalBackendPolicy` member. Upstream
refactors no longer conflict because they touch the call-site uniformly
for all profiles.
