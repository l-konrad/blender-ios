# iOS Architecture Overview

This document describes how the iOS / iPadOS port slots into Blender's
existing module structure.

## Layering

```
 ┌──────────────────────────────────────────────────────────────┐
 │   UIKit app entry point  (release/ios/Blender.app/*)         │
 └──────────────────────────────────────────────────────────────┘
                           │  (Info.plist, Main.storyboard, assets)
                           ▼
 ┌──────────────────────────────────────────────────────────────┐
 │   GHOST iOS backend  (intern/ghost/intern/GHOST_*IOS.{hh,mm})│
 │   - GHOST_SystemIOS    app delegate, event loop              │
 │   - GHOST_WindowIOS    UIView / MTKView hosting              │
 │   - GHOST_ContextIOS   Metal layer setup                     │
 │   - GHOST_KeyboardIOS  on-screen keyboard                    │
 │   - GHOST_FilePickerIOS UIDocumentPickerViewController       │
 └──────────────────────────────────────────────────────────────┘
                           │  GHOST_C-api  (C ABI)
                           ▼
 ┌──────────────────────────────────────────────────────────────┐
 │   WindowManager  (source/blender/windowmanager/)             │
 │   └─ wm_ios_bridge.{h,cc}  (C-linkage callbacks from GHOST)  │
 └──────────────────────────────────────────────────────────────┘
                           │
                           ▼
 ┌──────────────────────────────────────────────────────────────┐
 │   Editors / BKE / DNA / GPU / Cycles / Python                │
 └──────────────────────────────────────────────────────────────┘
```

## Key build switches

| CMake variable | Meaning |
|---|---|
| `APPLE_TARGET_DEVICE` | `macos` / `ios` / `ios-simulator` — chosen at the top-level `CMakeLists.txt` |
| `WITH_APPLE_CROSSPLATFORM` | Legacy umbrella flag. ON iff targeting iOS or iOS-simulator. Adds `-DWITH_APPLE_CROSSPLATFORM` compile define. |
| `APPLE_TARGET_IOS` | Internal: target is a physical iOS device (not simulator). |
| `LIBDIR` | Root of pre-built third-party libraries (`lib/ios_arm64/` or `lib/macos_arm64/`). |

`WITH_APPLE_CROSSPLATFORM` is heavily overloaded today — see
[feature_matrix.md](feature_matrix.md) and [proposals.md](proposals.md#p1).

## The WM ↔ GHOST bridge

GHOST is built as a standalone static library and historically calls into
the Blender Window Manager only through GHOST's own `GHOST_ISystem*`
callback interface. On iOS the platform layer needs Blender-specific
semantics (autosave on background, free memory on pressure, adjust autosave
timer when app is suspended), which don't fit a generic GHOST concept.

The solution is
[`source/blender/windowmanager/wm_ios_bridge.h`](../../source/blender/windowmanager/wm_ios_bridge.h):
a small C-linkage surface exposing:

```c
void WM_ios_autosave(void *ghost_context);
void WM_ios_autosave_timer_begin(void *ghost_context);
void WM_ios_autosave_timer_end(void *ghost_context);
void WM_ios_reduce_memory(void *ghost_context);
```

`GHOST_SystemIOS.mm` invokes these from its `UIScene` lifecycle callbacks;
the implementations in
[`wm_ios_bridge.cc`](../../source/blender/windowmanager/intern/wm_ios_bridge.cc)
are the only iOS-specific code in the WM that can be reasoned about as a
closed API surface.

**This pattern should expand** — see [proposals.md](proposals.md#p4) for
the formalized `GHOST_HostCallbacks` design that generalizes it for
macOS/Wayland sandboxing as well.

## The iOS-specific GHOST C-API surface

`GHOST_C-api.cc` gained ~1,337 lines of iOS-only entry points
(`GHOST_popupOnScreenKeyboard`, `GHOST_openFilePicker`, touch-event
emission helpers, etc.). These are currently interleaved with the
cross-platform API in the same files — [proposals.md](proposals.md#p3)
proposes splitting them into `GHOST_C-api_ios.{h,cc}`.

## Metal / Cycles

| Location | Role on iOS |
|---|---|
| `source/blender/gpu/metal/` | Shared with macOS. iOS-specific caps (no SIMD subgroup ops, different texture sampler limits) are `#ifdef`'d. |
| `intern/cycles/device/metal/` | Shared with macOS. iOS disables binary archives conditionally, reduces shader compile parallelism (avoid `jetsam`), and stubs PathTracer features requiring absent GPU features. |

The Cycles Metal path has high rebase churn (multiple "fix after rebase"
commits) because upstream refactors this code often. The
[MetalBackendProfile proposal](proposals.md#p11) addresses this.

## Bundle layout (runtime)

```
 Blender.app/
 ├─ Blender                    (main executable)
 ├─ Info.plist, PkgInfo
 ├─ Assets.car                 (compiled asset catalog)
 ├─ Main.storyboardc/          (compiled storyboard)
 ├─ Assets/                    (Blender data files)
 │  ├─ 4.6/                    (BLENDER_VERSION)
 │  │  ├─ scripts/             (startup, modules, addons_core, Cycles)
 │  │  ├─ datafiles/           (fonts, icons, startup.blend, assets, locale)
 │  │  ├─ python/              (Python 3.13+ runtime, trimmed)
 │  │  └─ extensions/          (system extensions placeholder)
 │  └─ lib/                    (bundled + signed dylibs)
 └─ _CodeSignature/
```

The `Assets/` tree is materialized by
[`release/ios/scripts/copy_bundle_data.sh`](../../release/ios/scripts/copy_bundle_data.sh)
at build-time (not at install-time) so Xcode can deploy directly to device.
