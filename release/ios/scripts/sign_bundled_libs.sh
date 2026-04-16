#!/bin/bash
# SPDX-FileCopyrightText: 2024-2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Sign all dylibs in the given destination directory with the current
# Xcode signing identity (EXPANDED_CODE_SIGN_IDENTITY), falling back to
# ad-hoc signing (`-`) when no identity is set (e.g. local simulator
# builds).
#
# Arguments:
#   $1  Absolute path to the directory containing the .dylib files.

set -euo pipefail

DEST="${1:?Missing argument: dylib destination directory}"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"

for f in "$DEST"/*.dylib; do
  [ -f "$f" ] || continue
  codesign --force --sign "$IDENTITY" "$f"
done
