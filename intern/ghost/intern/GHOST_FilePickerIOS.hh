/* SPDX-FileCopyrightText: 2025 Blender Authors
 *
 * SPDX-License-Identifier: GPL-2.0-or-later */

/** \file
 * \ingroup GHOST
 * Security-scoped URL storage and native file picker for iOS.
 */

#pragma once

#ifdef __OBJC__
#  import <Foundation/Foundation.h>
#endif

/**
 * Store a security-scoped URL (and its parent directory) so Blender can
 * later regain sandbox access for reading/writing.
 */
void GHOST_ios_storeSecurityScopedURL(void *nsurl);

/**
 * Look up a previously stored security-scoped NSURL for the given path.
 * \return An NSURL* (cast to void*) or nullptr if not found.
 */
void *GHOST_ios_lookupSecurityScopedURL(const char *filepath);
