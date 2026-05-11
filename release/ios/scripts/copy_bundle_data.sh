#!/bin/bash
# SPDX-FileCopyrightText: 2024-2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copy Blender data files (scripts, datafiles, Python runtime, Cycles
# kernel sources) into the iOS app bundle at build-time, so Xcode can
# deploy directly to device without `cmake --install`.
#
# Arguments:
#   $1  Absolute path to the Assets/ directory inside the .app bundle.
#
# Environment variables (set by the invoking CMake target):
#   SRC_DIR           Blender source tree root (CMAKE_SOURCE_DIR).
#   BUILD_DIR         Blender build tree root  (CMAKE_BINARY_DIR).
#   LIBDIR            Pre-built dependency prefix.
#   BLENDER_VERSION   e.g. "4.6".
#   PYTHON_VERSION    e.g. "3.13".

set -euo pipefail

BUNDLE_ASSETS="${1:?Missing argument: Assets directory path}"
: "${SRC_DIR:?SRC_DIR must be set}"
: "${BUILD_DIR:?BUILD_DIR must be set}"
: "${LIBDIR:?LIBDIR must be set}"
: "${BLENDER_VERSION:?BLENDER_VERSION must be set}"
: "${PYTHON_VERSION:?PYTHON_VERSION must be set}"

DEST="$BUNDLE_ASSETS/$BLENDER_VERSION"
mkdir -p "$DEST/datafiles"

# ── Scripts ──────────────────────────────────────────────────────────
# Always refresh so source edits propagate; rsync only updates changed files.
echo "Syncing Blender scripts..."
rsync -a --delete-excluded --exclude='.git' --exclude='__pycache__' \
  --exclude='.gitignore' --exclude='site' \
  "$SRC_DIR/scripts/" "$DEST/scripts/"

# ── Cycles addon (lives outside scripts/, installed via delayed_install) ──
# Always refresh: the addon source changes frequently, and a stale bundled
# properties.py causes RNA_*_get failures at runtime.
echo "Syncing Cycles addon..."
mkdir -p "$DEST/scripts/addons_core/cycles"
cp -f "$SRC_DIR/intern/cycles/blender/addon/"*.py "$DEST/scripts/addons_core/cycles/"

# ── Cycles kernel sources (needed for Metal JIT compilation) ──────────
if [ ! -d "$DEST/scripts/addons_core/cycles/source" ]; then
  echo "Copying Cycles kernel sources for Metal..."
  CYCLES_SRC="$SRC_DIR/intern/cycles"
  CYCLES_DST="$DEST/scripts/addons_core/cycles"

  # Kernel headers and sources (entire kernel tree).
  for kdir in bake bvh camera closure device/gpu device/metal film geom integrator light osl sample svm util; do
    if [ -d "$CYCLES_SRC/kernel/$kdir" ]; then
      mkdir -p "$CYCLES_DST/source/kernel/$kdir"
      cp -f "$CYCLES_SRC/kernel/$kdir/"*.h "$CYCLES_DST/source/kernel/$kdir/" 2>/dev/null || true
      cp -f "$CYCLES_SRC/kernel/$kdir/"*.metal "$CYCLES_DST/source/kernel/$kdir/" 2>/dev/null || true
    fi
  done
  # Top-level kernel headers.
  cp -f "$CYCLES_SRC/kernel/"*.h "$CYCLES_DST/source/kernel/" 2>/dev/null || true

  # Util headers (referenced by kernels).
  if [ -d "$CYCLES_SRC/util" ]; then
    mkdir -p "$CYCLES_DST/source/util"
    cp -f "$CYCLES_SRC/util/"*.h "$CYCLES_DST/source/util/" 2>/dev/null || true
  fi

  # Cycles license files.
  if [ -d "$CYCLES_SRC/doc/license" ]; then
    mkdir -p "$CYCLES_DST/license"
    cp -f "$CYCLES_SRC/doc/license/"* "$CYCLES_DST/license/" 2>/dev/null || true
  fi
fi

# ── Remove addons that require Python >= 3.12 (type alias syntax) ──
if [ -d "$DEST/scripts/addons_core/bl_pkg" ]; then
  echo "Removing bl_pkg addon (requires Python 3.12+)..."
  rm -rf "$DEST/scripts/addons_core/bl_pkg"
fi

# ── Datafiles: fonts, icons, colormanagement, studiolights ──────────
for subdir in fonts icons colormanagement studiolights cursors; do
  if [ -d "$SRC_DIR/release/datafiles/$subdir" ] && [ ! -d "$DEST/datafiles/$subdir" ]; then
    echo "Copying datafiles/$subdir..."
    rsync -a "$SRC_DIR/release/datafiles/$subdir/" "$DEST/datafiles/$subdir/"
  fi
done

# ── Datafiles: startup.blend, preview scenes ────────────────────────
for blend_file in startup.blend preview.blend preview_grease_pencil.blend; do
  if [ -f "$SRC_DIR/release/datafiles/$blend_file" ] && [ ! -f "$DEST/datafiles/$blend_file" ]; then
    echo "Copying datafiles/$blend_file..."
    cp -f "$SRC_DIR/release/datafiles/$blend_file" "$DEST/datafiles/"
  fi
done

# ── Extensions directory (system placeholder) ───────────────────────
if [ -d "$SRC_DIR/release/extensions" ] && [ ! -d "$DEST/extensions" ]; then
  echo "Copying extensions directory..."
  rsync -a "$SRC_DIR/release/extensions/" "$DEST/extensions/"
fi

# ── Assets: bundled brushes, nodes, catalog ─────────────────────────
if [ -d "$SRC_DIR/assets" ] && [ ! -d "$DEST/datafiles/assets/brushes" ]; then
  echo "Copying brush and node assets..."
  mkdir -p "$DEST/datafiles/assets"
  rsync -a --exclude='.git' --exclude='LICENSE' \
    "$SRC_DIR/assets/" "$DEST/datafiles/assets/"
fi

# ── Patch OCIO config for iOS (bundled library is v2.4, config is v2.5) ──
OCIO_CFG="$DEST/datafiles/colormanagement/config.ocio"
if [ -f "$OCIO_CFG" ]; then
  if grep -q 'ocio_profile_version: 2.5' "$OCIO_CFG"; then
    echo "Patching OCIO config for v2.4 compatibility..."
    sed -i '' \
      -e 's/ocio_profile_version: 2.5/ocio_profile_version: 2.4/' \
      -e '/^[[:space:]]*interop_id:/d' \
      -e '/^[[:space:]]*icc_profile_name:/d' \
      "$OCIO_CFG"
  fi
fi

# ── Locale: compiled .mo files from build directory ─────────────────
if [ ! -d "$DEST/datafiles/locale" ]; then
  echo "Copying locale files..."
  LOCALE_DEST="$DEST/datafiles/locale"
  mkdir -p "$LOCALE_DEST"
  if [ -f "$SRC_DIR/locale/languages" ]; then
    cp -f "$SRC_DIR/locale/languages" "$LOCALE_DEST/"
  fi
  for mo in "$BUILD_DIR"/source/creator/*.mo; do
    [ -f "$mo" ] || continue
    LANG_NAME=$(basename "$mo" .mo)
    mkdir -p "$LOCALE_DEST/$LANG_NAME/LC_MESSAGES"
    cp -f "$mo" "$LOCALE_DEST/$LANG_NAME/LC_MESSAGES/blender.mo"
  done
fi

# ── Python runtime ──────────────────────────────────────────────────
if [ ! -d "$DEST/python/lib/python$PYTHON_VERSION" ]; then
  echo "Copying Python runtime..."
  mkdir -p "$DEST/python/lib"
  rsync -a --exclude='__pycache__' --exclude='test' --exclude='tests' \
    --exclude='tkinter' --exclude='idlelib' --exclude='turtle*' \
    --exclude='ensurepip' \
    --exclude='*.so' --exclude='*.dylib' \
    "$LIBDIR/python/lib/python$PYTHON_VERSION/" \
    "$DEST/python/lib/python$PYTHON_VERSION/"
  if [ -f "$LIBDIR/python/bin/python$PYTHON_VERSION" ]; then
    mkdir -p "$DEST/python/bin"
    cp -f "$LIBDIR/python/bin/python$PYTHON_VERSION" "$DEST/python/bin/"
  fi
fi

# ── Clean macOS native extensions from site-packages (wrong platform) ──
if [ -d "$DEST/python/lib/python$PYTHON_VERSION/site-packages" ]; then
  REMOVED=$(find "$DEST/python/lib/python$PYTHON_VERSION/site-packages" \
    \( -name '*.so' -o -name '*.dylib' \) -delete -print 2>/dev/null | wc -l)
  if [ "$REMOVED" -gt 0 ]; then
    echo "Removed $REMOVED macOS native extensions from site-packages."
  fi
fi

echo "Bundle data files ready."
