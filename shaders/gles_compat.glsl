// Copyright 2026, Sebastian Degenaar for pixel-innovations.com (liquid_glass_widgets)
//
// SPDX-License-Identifier: MIT
//
// OpenGL ES texture-origin compatibility.
//
// Impeller's GLES backend used to store render-to-texture content with GL's
// native bottom-left origin, while Metal and Vulkan stored it top-down. Every
// fragment shader that sampled a Flutter-provided texture (a BackdropFilter
// snapshot) had to compensate by hand. Flutter PR #186556 absorbed that
// difference inside the GLES backend ("Retire Y-coord-scale plumbing by
// flipping GLES at the vertex stage"), and `impellerc` started defining
// IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED for exactly this detection.
//
// Presence of that macro ⇒ textures are already top-down, do NOT flip.
// Absence on a GLES stage ⇒ Flutter 3.44/3.45, still needs the flip.
//
// NOTE: this is about the *texture sampling* convention only. It does not
// affect FlutterFragCoord(), which has always reported Y-down positions.

#ifndef MINT_GLES_COMPAT_GLSL_
#define MINT_GLES_COMPAT_GLSL_

#if defined(IMPELLER_TARGET_OPENGLES) && \
    !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
// Flutter 3.44 / 3.45 GLES: textures are bottom-left origin, flip by hand.
#define MINT_GLES_FLIP_SAMPLE_Y 1
#endif

#endif  // MINT_GLES_COMPAT_GLSL_
