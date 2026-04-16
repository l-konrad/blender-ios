# Known iOS Issues

Tracked replacements for the legacy `IOS_FIXME` comment markers that used
to be scattered through the code. Each issue has an ID (`IOS-NNN`) that
source comments now reference as `TODO(iOS IOS-NNN)`.

Add new issues to this file **before** introducing a `TODO(iOS …)` in
code.

---

## IOS-001 — `BLI_Vector` size mismatch between host tools and target

- **File:** [source/blender/blenlib/BLI_vector.hh](../../source/blender/blenlib/BLI_vector.hh)
  (search for `IOS-001`)
- **Severity:** **High** — ABI concern for `.blend` interop and for
  cross-compiled host tools (`makesrna`, `makesdna`, `datatoc`).
- **Symptom:** The cross-compiled tools run on the host (macOS arm64) but
  emit data consumed by the iOS target build. If `sizeof(blender::Vector<T>)`
  differs between host and target, generated offsets are wrong.
- **Current workaround:** Padding in `Vector` to keep layout identical on
  both. Fragile.
- **Proper fix:** Audit all inline storage / small-buffer fields in
  `Vector`, `Array`, `Map`, and related containers. Either freeze the
  layout with static asserts checked on both host and target, or move host
  tools to emit only layout-independent representations.

## IOS-002 — Metal parallel shader compilation limit

- **File:** [source/blender/gpu/metal/mtl_backend.mm](../../source/blender/gpu/metal/mtl_backend.mm)
- **Severity:** Medium — performance, not correctness.
- **Symptom:** Unlimited concurrent Metal shader compilation causes the
  iOS kernel to `jetsam`-kill Blender under memory pressure on older
  iPads.
- **Current workaround:** Cap `_gpu_shader_compilation_subsystem_thread_count`
  to a low value on iOS.
- **Proper fix:** Query thermal + memory state via
  `NSProcessInfo.thermalState` / `os_proc_available_memory()` and scale
  dynamically. Share the policy with the Cycles Metal compile queue (see
  IOS-005).

## IOS-003 — 2D Full Canvas viewport -1 origin

- **File:** [source/blender/gpu/intern/gpu_framebuffer_private.hh](../../source/blender/gpu/intern/gpu_framebuffer_private.hh)
- **Severity:** Low.
- **Symptom:** Selecting the 2D Full Canvas window in the UI produces a
  viewport whose origin is `(-1, -1)`; the off-by-one gets clamped to 0
  in the Metal backend.
- **Proper fix:** Trace the origin computation in the editors layer and
  correct the off-by-one there, rather than masking it in GPU.

## IOS-004 — Text-edit event plumbing from UIKit to WM

- **Files:**
  [source/blender/windowmanager/wm_event_types.hh](../../source/blender/windowmanager/wm_event_types.hh),
  [source/blender/windowmanager/intern/wm_event_system.cc](../../source/blender/windowmanager/intern/wm_event_system.cc)
- **Severity:** Medium — functional hack.
- **Symptom:** The iOS on-screen keyboard emits text as `UITextInput`
  delegate callbacks, not as key events. Current plumbing injects them
  through a synthesized event type that partly shadows the desktop key
  event pipeline.
- **Proper fix:** Introduce a first-class `wmEvent_TextInput` event kind
  handled alongside `KM_PRESS`, and route on-screen keyboard output into
  that. Keep desktop key events unaffected.

## IOS-005 — Cycles Metal iOS ↔ macOS policy ping-pong

- **File:** [intern/cycles/device/metal/kernel.mm](../../intern/cycles/device/metal/kernel.mm)
- **Severity:** **High** maintenance burden (not a runtime bug).
- **Symptom:** Every rebase onto upstream Cycles Metal work re-conflicts
  this file because iOS-specific branches live as inline `#ifdef
  WITH_APPLE_CROSSPLATFORM` inside tight loops.
- **Proper fix:** [`proposals.md#p11`](proposals.md#p11) — route decisions
  through a single `MetalBackendProfile` policy object.

## IOS-006 — UI keyboard popup uses long-winded coordinate math

- **File:** [source/blender/editors/interface/interface_handlers.cc](../../source/blender/editors/interface/interface_handlers.cc)
- **Severity:** Low — code hygiene.
- **Symptom:** To show the on-screen keyboard anchored to a text field,
  the code recomputes window→screen coordinates and samples the button
  font manually.
- **Proper fix:** Expose a helper `UI_but_screen_rect(…)` in
  `UI_interface_rect.hh` that returns the display-space rect + resolved
  font + color; the iOS popup path becomes a two-line call.

## IOS-007 — View3D gizmo navigate: `NULL` region pointer

- **File:** [source/blender/editors/space_view3d/view3d_gizmo_navigate.cc](../../source/blender/editors/space_view3d/view3d_gizmo_navigate.cc)
- **Severity:** Low — guarded with null check.
- **Symptom:** Accessing the navigate gizmo sometimes returns `NULL`
  during the first frame of a new 3D view.
- **Proper fix:** Ensure the navigate gizmo is registered before the first
  draw of a newly-created 3D view. Likely a timing issue around UIScene
  restoration.

---

## Legacy `IOS_FIXME` markers

The `IOS_FIXME` string was used during initial bring-up as a grep-able
marker. It is **deprecated** in favor of `TODO(iOS IOS-NNN)` pointing into
this file. If you add a new concern, add an entry here first.

To find any remaining legacy markers:

```sh
grep -rn 'IOS_FIXME' source intern \
  --include='*.cc' --include='*.mm' --include='*.h' --include='*.hh'
```
