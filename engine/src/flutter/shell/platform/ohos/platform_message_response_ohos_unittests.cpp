/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

#define FML_USED_ON_EMBEDDER

#define private public
#include "flutter/shell/platform/ohos/napi/platform_view_ohos_napi.h"
#undef private

#include "flutter/shell/platform/ohos/platform_message_response_ohos.h"

#include "flutter/fml/mapping.h"
#include "flutter/fml/message_loop.h"
#include "flutter/shell/platform/ohos/napi/platform_view_ohos_napi.h"
#include "flutter/shell/platform/ohos/test_stubs/ace_napi_stub.h"
#include "gtest/gtest.h"

namespace flutter {
namespace testing {

// PlatformMessageResponseOHOS::Complete / CompleteEmpty post a task to the
// platform task runner that calls FlutterViewHandlePlatformMessageResponse.
// The NAPI stubs (ace_napi_stub.cc, linked into flutter_ohos_unittests) make
// it safe to invoke that method with a nullptr napi_env.
class PlatformMessageResponseOHOSTest : public ::testing::Test {
 protected:
  void SetUp() override {
    StubNapiReset();
    saved_env_ = PlatformViewOHOSNapi::env_;
    PlatformViewOHOSNapi::env_ = reinterpret_cast<napi_env>(0xF00D);
    fml::MessageLoop::EnsureInitializedForCurrentThread();
    runner_ = fml::MessageLoop::GetCurrent().GetTaskRunner();
  }

  void TearDown() override {
    PlatformViewOHOSNapi::env_ = saved_env_;
    StubNapiReset();
  }

  fml::RefPtr<fml::TaskRunner> runner_;
  napi_env saved_env_ = nullptr;
};

TEST_F(PlatformMessageResponseOHOSTest, CompletePostsResponseWithData) {
  auto napi_facade = std::make_shared<PlatformViewOHOSNapi>(nullptr);
  auto response = fml::MakeRefCounted<PlatformMessageResponseOHOS>(
      42, napi_facade, runner_);

  auto data = std::make_unique<fml::DataMapping>(std::vector<uint8_t>{1, 2, 3});
  response->Complete(std::move(data));

  // Execute the posted task synchronously.
  fml::MessageLoop::GetCurrent().RunExpiredTasksNow();
  // Verify the posted task actually invoked the JS method via NAPI stubs.
  EXPECT_GT(StubNapiCallFunctionCount(), 0u);
}

TEST_F(PlatformMessageResponseOHOSTest, CompleteEmptyPostsResponseWithoutData) {
  auto napi_facade = std::make_shared<PlatformViewOHOSNapi>(nullptr);
  auto response = fml::MakeRefCounted<PlatformMessageResponseOHOS>(
      99, napi_facade, runner_);

  response->CompleteEmpty();

  // Execute the posted task synchronously.
  fml::MessageLoop::GetCurrent().RunExpiredTasksNow();
  // Verify the posted task actually invoked the JS method via NAPI stubs.
  EXPECT_GT(StubNapiCallFunctionCount(), 0u);
}

}  // namespace testing
}  // namespace flutter
