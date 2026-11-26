/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

#include "flutter/shell/platform/ohos/napi/platform_view_ohos_napi.h"
#include "flutter/shell/platform/ohos/ohos_context_gl_impeller.h"
#include "flutter/shell/platform/ohos/ohos_display.h"

#include "gtest/gtest.h"

namespace flutter {
namespace testing {

// OHOSDisplay reads display geometry from static fields on
// PlatformViewOHOSNapi. Save and restore them so the test is hermetic.
class OHOSDisplayTest : public ::testing::Test {
 protected:
  void SetUp() override {
    saved_width_ = PlatformViewOHOSNapi::display_width;
    saved_height_ = PlatformViewOHOSNapi::display_height;
    saved_refresh_ = PlatformViewOHOSNapi::display_refresh_rate;
    saved_density_ = PlatformViewOHOSNapi::display_density_pixels;
  }

  void TearDown() override {
    PlatformViewOHOSNapi::display_width = saved_width_;
    PlatformViewOHOSNapi::display_height = saved_height_;
    PlatformViewOHOSNapi::display_refresh_rate = saved_refresh_;
    PlatformViewOHOSNapi::display_density_pixels = saved_density_;
  }

 private:
  int64_t saved_width_ = 0;
  int64_t saved_height_ = 0;
  int32_t saved_refresh_ = 0;
  double saved_density_ = 0.0;
};

TEST_F(OHOSDisplayTest, GettersReflectStaticDisplayFields) {
  PlatformViewOHOSNapi::display_width = 1080;
  PlatformViewOHOSNapi::display_height = 2400;
  PlatformViewOHOSNapi::display_refresh_rate = 120;
  PlatformViewOHOSNapi::display_density_pixels = 3.0;

  auto napi_facade = std::make_shared<PlatformViewOHOSNapi>(nullptr);
  OHOSDisplay display(napi_facade);

  EXPECT_DOUBLE_EQ(display.GetWidth(), 1080.0);
  EXPECT_DOUBLE_EQ(display.GetHeight(), 2400.0);
  EXPECT_DOUBLE_EQ(display.GetRefreshRate(), 120.0);
  EXPECT_DOUBLE_EQ(display.GetDevicePixelRatio(), 3.0);
}

TEST_F(OHOSDisplayTest, ZeroValuesAreHandled) {
  PlatformViewOHOSNapi::display_width = 0;
  PlatformViewOHOSNapi::display_height = 0;
  PlatformViewOHOSNapi::display_refresh_rate = 0;
  PlatformViewOHOSNapi::display_density_pixels = 0.0;

  auto napi_facade = std::make_shared<PlatformViewOHOSNapi>(nullptr);
  OHOSDisplay display(napi_facade);

  EXPECT_DOUBLE_EQ(display.GetWidth(), 0.0);
  EXPECT_DOUBLE_EQ(display.GetHeight(), 0.0);
  EXPECT_DOUBLE_EQ(display.GetRefreshRate(), 0.0);
  EXPECT_DOUBLE_EQ(display.GetDevicePixelRatio(), 0.0);
}

TEST(OHOSContextGLImpellerTest, IsValidReturnsTrue) {
  OHOSContextGLImpeller context;
  EXPECT_TRUE(context.IsValid());
}

}  // namespace testing
}  // namespace flutter
