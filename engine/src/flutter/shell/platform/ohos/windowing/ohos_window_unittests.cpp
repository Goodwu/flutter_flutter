/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

#include <gtest/gtest.h>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <utility>
#include "flutter/common/settings.h"
#include "flutter/fml/log_settings.h"
#include "flutter/shell/platform/ohos/napi/platform_view_ohos_napi.h"
#include "flutter/shell/platform/ohos/windowing/ohos_window.h"

#define private public
#include "flutter/shell/platform/ohos/ohos_shell_holder.h"
#undef private

namespace flutter {
namespace testing {

namespace {

// The request callbacks are bare function pointers, so a per-file "current
// counter" is wired through statics; gtest runs each suite serially, so no
// cross-test interference.
struct CallbackCounters {
  int should_close = 0;
  int will_close = 0;
  int notify = 0;
};

CallbackCounters* g_counters = nullptr;

void OnShouldClose() {
  if (g_counters != nullptr) {
    ++g_counters->should_close;
  }
}

void OnWillClose() {
  if (g_counters != nullptr) {
    ++g_counters->will_close;
  }
}

void OnNotifyListeners() {
  if (g_counters != nullptr) {
    ++g_counters->notify;
  }
}

// Positioner behavior: when |g_positioner| is null the request has NO
// positioner; when return_null is set the callback returns nullptr (Dart-side
// allocation failure); otherwise it returns a malloc'd rect the production
// code free()s — must be libc-heap memory.
struct PositionerConfig {
  bool return_null = false;
  FlutterWindowRect rect{};
};

PositionerConfig* g_positioner = nullptr;

struct CallbackScope {
  explicit CallbackScope(CallbackCounters* counters) { g_counters = counters; }
  ~CallbackScope() { g_counters = nullptr; }
};

struct PositionerScope {
  explicit PositionerScope(PositionerConfig* config) { g_positioner = config; }
  ~PositionerScope() { g_positioner = nullptr; }
};

FlutterWindowRect* OnGetWindowPosition(const FlutterWindowSize& child_size,
                                       const FlutterWindowRect& parent_rect,
                                       const FlutterWindowRect& output_rect) {
  if (g_positioner == nullptr || g_positioner->return_null) {
    return nullptr;
  }
  FlutterWindowRect* out =
      static_cast<FlutterWindowRect*>(malloc(sizeof(FlutterWindowRect)));
  *out = g_positioner->rect;
  return out;
}

OHOSWindow::InitParams MakeParams(
    WindowType type = WindowType::kRegular,
    WindowHostKind kind = WindowHostKind::kUiAbility,
    int64_t view_id = 42,
    int64_t parent_view_id = 0) {
  OHOSWindow::InitParams params;
  params.type = type;
  params.host_kind = kind;
  params.view_id = view_id;
  params.parent_view_id = parent_view_id;
  return params;
}

class SoftwareHolderFacade {
 public:
  SoftwareHolderFacade() {
    Settings settings;
    settings.ohos_rendering_api = OHOSRenderingAPI::kSoftware;
    holder_ = std::make_unique<OHOSShellHolder>(
        settings, std::make_shared<PlatformViewOHOSNapi>(nullptr), nullptr);
    holder_->napi_facade_.reset();
  }

  void SetFacade(std::shared_ptr<PlatformViewOHOSNapi> facade) {
    holder_->napi_facade_ = std::move(facade);
  }

  OHOSWindowController* controller() const {
    return holder_->GetWindowController();
  }

 private:
  std::unique_ptr<OHOSShellHolder> holder_;
};

}  // namespace

// ---------------------------------------------------------------------------
// Construction + accessors
// ---------------------------------------------------------------------------

TEST(OHOSWindowTest, ConstructionExposesParams) {
  FlutterWindowCreationRequest request = {};
  request.has_size = true;
  request.size = {200.0, 100.0};
  request.has_constraints = true;
  request.constraints = {10.0, 20.0, 0.0, 0.0};
  request.has_parent = false;
  request.parent_view_id = 0;
  request.on_should_close = OnShouldClose;
  request.on_will_close = OnWillClose;
  request.notify_listeners = OnNotifyListeners;
  request.on_get_window_position = OnGetWindowPosition;

  // Controller-independent: nullptr is fine for every method below.
  OHOSWindow window(nullptr, MakeParams(), request);

  EXPECT_EQ(window.type(), WindowType::kRegular);
  EXPECT_EQ(window.host_kind(), WindowHostKind::kUiAbility);
  EXPECT_EQ(window.view_id(), 42);
  EXPECT_EQ(window.parent_view_id(), 0);
  // The request is value-copied into the window.
  EXPECT_EQ(window.request().size.width, 200.0);
  EXPECT_EQ(window.request().size.height, 100.0);
  EXPECT_TRUE(window.request().has_constraints);
  EXPECT_EQ(window.request().constraints.min_width, 10.0);
}

// ---------------------------------------------------------------------------
// Dart callbacks
// ---------------------------------------------------------------------------

TEST(OHOSWindowTest, FireCallbacksInvokeRequestHandlers) {
  CallbackCounters counters;
  CallbackScope scope(&counters);

  FlutterWindowCreationRequest request = {};
  request.on_should_close = OnShouldClose;
  request.on_will_close = OnWillClose;
  request.notify_listeners = OnNotifyListeners;

  OHOSWindow window(nullptr, MakeParams(), request);
  window.FireShouldClose();
  window.FireWillClose();
  window.FireNotifyListeners();

  EXPECT_EQ(counters.should_close, 1);
  EXPECT_EQ(counters.will_close, 1);
  EXPECT_EQ(counters.notify, 1);
}

TEST(OHOSWindowTest, FireCallbacksWithNullHandlersIsNoOp) {
  // No callbacks wired: firing must not crash.
  OHOSWindow window(nullptr, MakeParams(), {});
  window.FireShouldClose();
  window.FireWillClose();
  window.FireNotifyListeners();
}

// ---------------------------------------------------------------------------
// ComputeWindowPosition
// ---------------------------------------------------------------------------

TEST(OHOSWindowTest, ComputeWindowPositionRejectsNullOut) {
  PositionerConfig config;
  config.return_null = false;
  config.rect = {1.0, 2.0, 3.0, 4.0};
  PositionerScope scope(&config);

  FlutterWindowCreationRequest request = {};
  request.on_get_window_position = OnGetWindowPosition;
  OHOSWindow window(nullptr, MakeParams(), request);

  EXPECT_FALSE(window.ComputeWindowPosition({10, 10}, {0, 0, 100, 100},
                                            {0, 0, 800, 600}, nullptr));
}

TEST(OHOSWindowTest, ComputeWindowPositionWithoutPositioner) {
  OHOSWindow window(nullptr, MakeParams(), {});
  FlutterWindowRect out{99.0, 99.0, 99.0, 99.0};
  // Untouched on failure.
  EXPECT_FALSE(window.ComputeWindowPosition({10, 10}, {0, 0, 100, 100},
                                            {0, 0, 800, 600}, &out));
  EXPECT_EQ(out.left, 99.0);
  EXPECT_EQ(out.top, 99.0);
}

TEST(OHOSWindowTest, ComputeWindowPositionPositionerReturnsNull) {
  PositionerConfig config;
  config.return_null = true;
  PositionerScope scope(&config);

  FlutterWindowCreationRequest request = {};
  request.on_get_window_position = OnGetWindowPosition;
  OHOSWindow window(nullptr, MakeParams(), request);

  FlutterWindowRect out{};
  EXPECT_FALSE(window.ComputeWindowPosition({10, 10}, {0, 0, 100, 100},
                                            {0, 0, 800, 600}, &out));
}

TEST(OHOSWindowTest, ComputeWindowPositionCopiesResult) {
  PositionerConfig config;
  config.rect = {12.5, 30.0, 200.0, 150.0};
  PositionerScope scope(&config);

  FlutterWindowCreationRequest request = {};
  request.on_get_window_position = OnGetWindowPosition;
  OHOSWindow window(nullptr, MakeParams(), request);

  FlutterWindowRect out{};
  EXPECT_TRUE(window.ComputeWindowPosition({200, 150}, {10, 10, 300, 200},
                                           {0, 0, 800, 600}, &out));
  EXPECT_EQ(out.left, 12.5);
  EXPECT_EQ(out.top, 30.0);
  EXPECT_EQ(out.width, 200.0);
  EXPECT_EQ(out.height, 150.0);
}

// ---------------------------------------------------------------------------
// Sub-window birth sizing
// ---------------------------------------------------------------------------

TEST(OHOSWindowTest, GetSubWindowBirthSizePrefersRequestSize) {
  FlutterWindowCreationRequest request = {};
  request.has_size = true;
  request.size = {640.0, 480.0};
  request.has_constraints = true;
  request.constraints = {100.0, 80.0, 0.0, 0.0};
  OHOSWindow window(nullptr, MakeParams(), request);

  double width = -1.0;
  double height = -1.0;
  window.GetSubWindowBirthSize(width, height);
  EXPECT_EQ(width, 640.0);
  EXPECT_EQ(height, 480.0);
}

TEST(OHOSWindowTest, GetSubWindowBirthSizeFallsBackToMinConstraint) {
  FlutterWindowCreationRequest request = {};
  request.has_constraints = true;
  request.constraints = {100.0, 80.0, 0.0, 0.0};
  OHOSWindow window(nullptr, MakeParams(), request);

  double width = -1.0;
  double height = -1.0;
  window.GetSubWindowBirthSize(width, height);
  // Born small (min), not full-display.
  EXPECT_EQ(width, 100.0);
  EXPECT_EQ(height, 80.0);
}

TEST(OHOSWindowTest, GetSubWindowBirthSizeDefaultsToZero) {
  OHOSWindow window(nullptr, MakeParams(), {});
  double width = -1.0;
  double height = -1.0;
  window.GetSubWindowBirthSize(width, height);
  EXPECT_EQ(width, 0.0);
  EXPECT_EQ(height, 0.0);
}

// ---------------------------------------------------------------------------
// Title cache
// ---------------------------------------------------------------------------

TEST(OHOSWindowTest, TitleCacheRoundTrips) {
  OHOSWindow window(nullptr, MakeParams(), {});
  EXPECT_EQ(window.GetTitle(), "");
  window.SetTitleCache("multi-window title");
  EXPECT_EQ(window.GetTitle(), "multi-window title");
  window.SetTitleCache("replaced");
  EXPECT_EQ(window.GetTitle(), "replaced");
}

// ---------------------------------------------------------------------------
// Host request dispatch (host request needs a controller — see
// ohos_window_controller_unittests.cpp). The dispatch is data-driven on
// host_kind: kUiAbility routes to the UIAbility path (Regular + modeless
// Dialog), kSubWindow to the generic sub-window path (modal Dialog / tooltip
// / popup).
// ---------------------------------------------------------------------------

TEST(OHOSWindowTest, RequestWindowHostWithoutFacadeEarlyReturns) {
  SoftwareHolderFacade holder;
  EXPECT_EQ(holder.controller()->GetNapiFacade().get(), nullptr);
  OHOSWindow window(
      holder.controller(),
      MakeParams(WindowType::kDialog, WindowHostKind::kSubWindow, 7, 3), {});
  {
    fml::ScopedSetLogSettings loud({fml::kLogInfo});
    EXPECT_NO_FATAL_FAILURE(window.RequestWindowHost());
  }
  {
    fml::ScopedSetLogSettings quiet({fml::kLogFatal});
    EXPECT_NO_FATAL_FAILURE(window.RequestWindowHost());
  }
}

TEST(OHOSWindowTest, RequestWindowHostWithFacadeDispatches) {
  SoftwareHolderFacade holder;
  auto facade = std::make_shared<PlatformViewOHOSNapi>(nullptr);
  holder.SetFacade(facade);
  EXPECT_EQ(holder.controller()->GetNapiFacade().get(), facade.get());

  FlutterWindowCreationRequest request = {};
  request.has_size = true;
  request.size = {640.0, 480.0};
  OHOSWindow window(
      holder.controller(),
      MakeParams(WindowType::kDialog, WindowHostKind::kSubWindow, 7, 3),
      request);
  EXPECT_NO_FATAL_FAILURE(window.RequestWindowHost());
}

TEST(OHOSWindowTest, RequestUiAbilityHostWithoutFacadeEarlyReturns) {
  SoftwareHolderFacade holder;
  EXPECT_EQ(holder.controller()->GetNapiFacade().get(), nullptr);
  OHOSWindow window(
      holder.controller(),
      MakeParams(WindowType::kRegular, WindowHostKind::kUiAbility, 7, 0), {});
  EXPECT_NO_FATAL_FAILURE(window.RequestWindowHost());
}

TEST(OHOSWindowTest, RequestUiAbilityHostAdoptsEntryAbilityWithSize) {
  SoftwareHolderFacade holder;
  holder.SetFacade(std::make_shared<PlatformViewOHOSNapi>(nullptr));
  ASSERT_NE(holder.controller()->GetNapiFacade(), nullptr);

  FlutterWindowCreationRequest request = {};
  request.has_size = true;
  request.size = {800.0, 600.0};
  OHOSWindow window(holder.controller(),
                    MakeParams(WindowType::kRegular, WindowHostKind::kUiAbility,
                               kFlutterImplicitViewId, 0),
                    request);
  EXPECT_NO_FATAL_FAILURE(window.RequestWindowHost());
}

TEST(OHOSWindowTest, RequestUiAbilityHostAdoptsEntryAbilityWithoutSize) {
  SoftwareHolderFacade holder;
  holder.SetFacade(std::make_shared<PlatformViewOHOSNapi>(nullptr));
  ASSERT_NE(holder.controller()->GetNapiFacade(), nullptr);

  OHOSWindow window(holder.controller(),
                    MakeParams(WindowType::kRegular, WindowHostKind::kUiAbility,
                               kFlutterImplicitViewId, 0),
                    {});
  EXPECT_NO_FATAL_FAILURE(window.RequestWindowHost());
}

TEST(OHOSWindowTest, RequestUiAbilityHostCreatesRegularAbility) {
  SoftwareHolderFacade holder;
  holder.SetFacade(std::make_shared<PlatformViewOHOSNapi>(nullptr));
  ASSERT_NE(holder.controller()->GetNapiFacade(), nullptr);

  OHOSWindow window(
      holder.controller(),
      MakeParams(WindowType::kRegular, WindowHostKind::kUiAbility, 7, 0), {});
  EXPECT_NO_FATAL_FAILURE(window.RequestWindowHost());
}

}  // namespace testing
}  // namespace flutter
