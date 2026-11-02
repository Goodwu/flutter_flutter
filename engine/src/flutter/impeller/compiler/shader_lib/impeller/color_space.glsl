// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef COLOR_SPACE_GLSL_
#define COLOR_SPACE_GLSL_

#include <impeller/types.glsl>

// Must match impeller::ColorSpace in impeller/geometry/color.h.
const int kColorSpaceSRGB = 0;
const int kColorSpaceExtendedSRGB = 1;
const int kColorSpaceDisplayP3 = 2;

float IPSrgbChannelToLinear(float c) {
  c = max(c, 0.0);
  if (c <= 0.04045) {
    return c / 12.92;
  }
  return pow((c + 0.055) / 1.055, 2.4);
}

float IPLinearChannelToSrgb(float c) {
  c = max(c, 0.0);
  if (c <= 0.0031308) {
    return c * 12.92;
  }
  return 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

vec3 IPSrgbToLinear(vec3 color) {
  return vec3(IPSrgbChannelToLinear(color.r), IPSrgbChannelToLinear(color.g),
              IPSrgbChannelToLinear(color.b));
}

/// Applies the sRGB transfer function without clamping, so values outside
/// [0, 1] are preserved for extended range targets.
vec3 IPLinearToSrgb(vec3 color) {
  return vec3(IPLinearChannelToSrgb(color.r), IPLinearChannelToSrgb(color.g),
              IPLinearChannelToSrgb(color.b));
}

// https://www.w3.org/TR/css-color-4/
vec3 IPLinearSrgbToLinearP3(vec3 color) {
  return vec3(0.822461186547 * color.r + 0.177538013953 * color.g,
              0.033191798446 * color.r + 0.966808201554 * color.g,
              0.017055917378 * color.r + 0.072079544594 * color.g +
                  0.910864537928 * color.b);
}

vec3 IPLinearP3ToLinearSrgb(vec3 color) {
  return vec3(1.306671048092539 * color.r - 0.298061942172353 * color.g +
                  0.213228303487995 * color.b,
              -0.117390025596251 * color.r + 1.127722006101976 * color.g +
                  0.109727644608938 * color.b,
              0.214813187718391 * color.r + 0.054268702864647 * color.g +
                  1.406898424029350 * color.b);
}

/// Converts `color` from `source_color_space` to `target_color_space`.
///
/// The color space arguments carry impeller::ColorSpace values as floats.
vec4 IPConvertColorSpace(vec4 color,
                         float source_color_space,
                         float target_color_space) {
  int src = int(source_color_space + 0.5);
  int dst = int(target_color_space + 0.5);
  if (src == dst) {
    return color;
  }
  if (src != kColorSpaceDisplayP3 && dst == kColorSpaceDisplayP3) {
    color.rgb =
        IPLinearToSrgb(IPLinearSrgbToLinearP3(IPSrgbToLinear(color.rgb)));
  } else if (src == kColorSpaceDisplayP3 && dst != kColorSpaceDisplayP3) {
    color.rgb =
        IPLinearToSrgb(IPLinearP3ToLinearSrgb(IPSrgbToLinear(color.rgb)));
    if (dst == kColorSpaceSRGB) {
      color.rgb = clamp(color.rgb, 0.0, 1.0);
    }
  } else if (src == kColorSpaceExtendedSRGB && dst == kColorSpaceSRGB) {
    color.rgb = clamp(color.rgb, 0.0, 1.0);
  }
  return color;
}

#endif  // COLOR_SPACE_GLSL_
