# iOS Feature Matrix

Status of Blender features and third-party dependencies on iOS / iPadOS
(`WITH_APPLE_CROSSPLATFORM=ON`) vs. the desktop builds. This table is the
source of truth the scattered `#ifdef WITH_APPLE_CROSSPLATFORM` guards are
trying to encode.

Legend: ✅ enabled · ❌ disabled · 🟡 partial / with caveats · — N/A

## Rendering

| Feature                         | iOS | macOS | Notes |
|---------------------------------|-----|-------|-------|
| Metal GPU backend               | ✅  | ✅    | Shared `source/blender/gpu/metal/` |
| OpenGL backend                  | ❌  | 🟡    | iOS has no OpenGL |
| Vulkan backend                  | ❌  | ❌    | MoltenVK not built |
| Cycles CPU                      | ✅  | ✅    | |
| Cycles Metal                    | ✅  | ✅    | iOS uses binary archives; SIMD subgroup ops disabled |
| Cycles OptiX / HIP / oneAPI     | ❌  | ❌    | |
| EEVEE                           | ✅  | ✅    | iOS disables denoiser compute shaders with null-shader guards |
| HDR / EDR display               | ✅  | ✅    | |
| ProMotion (120 Hz)              | ✅  | —     | |

## Scene / Modeling

| Feature                         | iOS | macOS | Notes |
|---------------------------------|-----|-------|-------|
| OpenSubdiv                      | ✅  | ✅    | Enabled in `2590a20d5c2` |
| USD I/O                         | ❌  | ✅    | Disabled via `7f0df3f9dcf`; build patches exist |
| Alembic I/O                     | 🟡  | ✅    | Build requires platform-specific patches |
| OpenVDB                         | 🟡  | ✅    | |
| Draco (glTF)                    | 🟡  | ✅    | |
| MantaFlow (fluid sim)           | 🟡  | ✅    | |
| LibMV / Ceres (motion tracking) | ❌  | ✅    | Ceres optional; iOS falls back when missing |
| Quadriflow                      | 🟡  | ✅    | |

## Python

| Feature                             | iOS | macOS | Notes |
|-------------------------------------|-----|-------|-------|
| Python scripting                    | ✅  | ✅    | Python 3.13+ (iOS raised min via `e79f82c1b4d`) |
| Python `multiprocessing`            | ❌  | ✅    | iOS sandbox forbids `fork()` of new processes |
| Python site-packages native `.so`   | ❌  | ✅    | macOS binaries stripped from bundle at build time |
| `bl_pkg` addon                      | ❌  | ✅    | Removed at bundle-time (requires newer Python features) |
| `ensurepip`                         | ❌  | ✅    | Stripped from bundled Python runtime |

## Windowing / Input

| Feature                         | iOS | macOS | Notes |
|---------------------------------|-----|-------|-------|
| Multiple OS windows             | ❌  | ✅    | iOS suppresses new window creation |
| Native file picker              | ✅  | ✅    | iOS uses `UIDocumentPickerViewController` (security-scoped URLs) |
| On-screen keyboard              | ✅  | —     | `GHOST_popupOnScreenKeyboard` |
| Touch events (1–4 finger tap)   | ✅  | —     | |
| Apple Pencil                    | ✅  | —     | Stylus pressure + hover + tap |
| Bluetooth mouse/trackpad        | ✅  | ✅    | Scroll wheel via `048a9f19dde` |
| Edge-swipe gestures             | ✅  | —     | Inward swipe reserved for iOS shell |
| Portrait orientation            | ✅  | —     | |
| Home indicator auto-hide        | ✅  | —     | |

## Lifecycle / System

| Feature                         | iOS | macOS | Notes |
|---------------------------------|-----|-------|-------|
| UIScene lifecycle               | ✅  | —     | Adopted in `e1356ec95f8` |
| Memory-pressure response        | ✅  | —     | `WM_ios_reduce_memory` trims undo + GPU caches |
| Autosave on background          | ✅  | ✅    | iOS bridges via `WM_ios_autosave*` |
| Bundled data files in app       | ✅  | —     | `scripts/`, `datafiles/`, Cycles kernels, Python runtime |
| Bundled dylibs with signing     | ✅  | —     | Signed with Xcode identity at build-time |
| Xcode archiving (TestFlight)    | ✅  | —     | `dca16b3156b` |
| Background / App-Refresh tasks  | ❌  | —     | Not yet wired |

## Build

| Item                            | iOS | macOS | Notes |
|---------------------------------|-----|-------|-------|
| CMake generator                 | Xcode | Xcode/Make/Ninja | |
| Cross-compile host libs         | required | — | `lib/ios_arm64` + `lib/macos_arm64` both needed |
| Simulator                       | ✅  | —     | `APPLE_TARGET_DEVICE=ios-simulator` |
| Code signing at build time      | ✅  | —     | `EXPANDED_CODE_SIGN_IDENTITY`, ad-hoc fallback |

---

## How to read the `#ifdef` guards

A guard like `#ifdef WITH_APPLE_CROSSPLATFORM` semantically means *at least
one* of:

1. the iOS SDK does not provide a symbol the code uses;
2. the iOS sandbox or App Store policy forbids the runtime behavior;
3. the feature is temporarily stubbed awaiting an iOS-native implementation;
4. a third-party dependency is not (yet) built for the iOS library bundle.

Category (4) guards are the most common and — per [proposals.md](proposals.md)
— should be replaced with the existing Blender `WITH_<DEPENDENCY>` flags
rather than the iOS umbrella.
