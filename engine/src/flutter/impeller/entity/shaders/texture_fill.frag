// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

precision mediump float;

#include <impeller/color_space.glsl>
#include <impeller/constants.glsl>
#include <impeller/types.glsl>

uniform f16sampler2D texture_sampler;

uniform FragInfo {
  float alpha;
  float source_color_space;
  float target_color_space;
}
frag_info;

in highp vec2 v_texture_coords;

out f16vec4 frag_color;

void main() {
  f16vec4 sampled =
      texture(texture_sampler, v_texture_coords, float16_t(kDefaultMipBias));
  frag_color = f16vec4(IPConvertColorSpace(vec4(sampled) * frag_info.alpha,
                                           frag_info.source_color_space,
                                           frag_info.target_color_space));
}
