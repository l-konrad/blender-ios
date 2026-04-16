# Rebasing `ios-new` onto upstream `blender/main`

The iOS fork touches several high-churn files in upstream
(`wm_event_system.cc`, `interface_handlers.cc`, `mtl_backend.mm`,
`intern/cycles/device/metal/kernel.mm`, `draw_pass.hh`). Rebasing
without preparation guarantees conflicts. This document captures the
workflow that works.

## 0. Prerequisites

- Remotes set up:
  - `origin` → `https://github.com/blender/blender.git` (upstream)
  - `fork`   → your own iOS fork (SSH preferred)
- Working tree clean.
- Disk space for the backup branch.

## 1. Fetch and back up

```sh
git fetch origin
git fetch fork
git branch "ios-new-backup-$(date +%Y%m%d-%H%M%S)" ios-new
```

The backup branch is your emergency exit.

## 2. Avoid LFS and credential prompts

Blender's `main` contains files stored in an LFS pointer that, when
fetched from an unconfigured mirror, will block on an interactive
credential prompt for `https://projects.blender.org`. Disable that for
the rebase:

```sh
export GIT_LFS_SKIP_SMUDGE=1
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/usr/bin/true
```

## 3. Rebase with non-interactive editor

```sh
git checkout ios-new
git -c core.editor=true rebase origin/main
```

`core.editor=true` keeps rebase from opening an editor on every commit
message, which is important when you expect conflicts.

## 4. Resolving conflicts

For each conflict, decide which side to keep using these rules.

| File pattern | Default resolution |
|---|---|
| `intern/cycles/device/metal/kernel.mm` | Keep `HEAD` (upstream) — subsequent iOS commits in the rebase will re-introduce the required `#ifdef` guards. |
| `intern/cycles/device/metal/*.mm` (other) | Case-by-case; usually keep upstream structure, replay the iOS `#ifdef` region. |
| `source/blender/gpu/metal/mtl_backend.mm` | Keep upstream; iOS-specific caps are additive at the end of the function. |
| `source/blender/editors/interface/interface_handlers.cc` | Merge — preserve the iOS `GHOST_popupOnScreenKeyboard` block *and* upstream's changes. |
| `source/blender/draw/intern/draw_pass.hh` | Merge — the iOS null-shader guard is a 2-line addition; keep upstream refactor. |
| `build_files/cmake/platform/platform_apple.cmake` | Keep the iOS branch (Ceres fallback) and the upstream changes together. |
| `build_files/build_environment/cmake/*.cmake` | Keep upstream unless the change is explicitly iOS (guarded by `APPLE_TARGET_IOS` / `APPLE_TARGET_DEVICE`). |
| `source/creator/CMakeLists.txt` | Merge carefully — the iOS bundle block is large and self-contained; apply around it. |

**Rule of thumb:** if a file has later iOS commits in the rebase that
touch the same lines, take upstream first — the later iOS commits will
re-apply the needed changes. This avoids double-resolving.

## 5. Continuing

```sh
git add <resolved-files>
git -c core.editor=true rebase --continue
```

Never `git rebase --skip` unless the commit is explicitly described as
"fix build after rebase" — those are transient and can be dropped.

## 6. Post-rebase validation

```sh
git status              # must be clean
git log --oneline origin/main..HEAD | wc -l   # expected ~47 iOS commits
git diff origin/main..HEAD --stat | tail -1   # sanity-check LOC totals
```

Configure iOS build (does not require a device):

```sh
rm -rf build_ios
./setup_ios.sh --auto     # or manual cmake invocation below
```

Manual configure-only check:

```sh
cmake -S . -B build_ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DAPPLE_TARGET_DEVICE=ios \
  -DWITH_APPLE_CROSSPLATFORM=ON
```

This is what the CI workflow in
[`.github/workflows/ios-configure.yml`](../../.github/workflows/ios-configure.yml)
runs on every push.

## 7. Reducing future conflicts

- **Squash `fix-after-rebase` commits** into the parent commit whose
  regression they fix (`git rebase -i`). The history currently has 5+ of
  these; each is dead weight and multiplies conflict surface.
- **Upstream isolated improvements** — the null-shader guards, the
  ProMotion support, and the `enabled_tex_mask_` fix are not iOS-specific
  and should be submitted to Blender main as standalone patches. Once
  merged, they disappear from this branch.
- **Group by subsystem.** Consider consolidating all iOS Cycles changes
  into one commit, all iOS GHOST changes into one commit, etc. This
  trades bisectability for merge-ability — an acceptable trade when the
  fork is small and the rebase cadence is high.
