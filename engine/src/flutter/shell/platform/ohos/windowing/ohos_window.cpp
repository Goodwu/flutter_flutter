/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

#include "flutter/shell/platform/ohos/windowing/ohos_window.h"

#include <cstdlib>
#include <utility>

#include "flutter/common/constants.h"  // kFlutterImplicitViewId
#include "flutter/fml/logging.h"
#include "flutter/shell/platform/ohos/napi/platform_view_ohos_napi.h"
#include "flutter/shell/platform/ohos/windowing/ohos_window_controller.h"

namespace flutter {

OHOSWindow::OHOSWindow(OHOSWindowController* controller,
                       const InitParams& params,
                       const FlutterWindowCreationRequest& request)
    : controller_(controller),
      type_(params.type),
      host_kind_(params.host_kind),
      view_id_(params.view_id),
      parent_view_id_(params.parent_view_id),
      request_(request)
{
  title_ = request.title != nullptr ? request.title : "";
  request_.title = nullptr;
}

OHOSWindow::~OHOSWindow() = default;

void OHOSWindow::FireShouldClose()
{
  if (request_.on_should_close) {
    request_.on_should_close();
  }
}

void OHOSWindow::FireWillClose()
{
  if (request_.on_will_close) {
    request_.on_will_close();
  }
}

void OHOSWindow::FireNotifyListeners()
{
  if (request_.notify_listeners) {
    request_.notify_listeners();
  }
}

bool OHOSWindow::ComputeWindowPosition(const FlutterWindowSize& child_size,
                                       const FlutterWindowRect& parent_rect,
                                       const FlutterWindowRect& work_area,
                                       FlutterWindowRect* out)
{
  if (out == nullptr) {
    return false;
  }
  const auto& callback = request_.on_get_window_position;
  if (!callback) {
    // No positioner (Regular/Dialog, or tooltip/popup without one): leave
    // placement to the caller.
    return false;
  }
  // Synchronous Dart callback (safe from the napi thread, as on_will_close
  // proves). The callback returns a Dart-side calloc'd rect (logical px);
  // copy the values, then free (same libc heap).
  FlutterWindowRect* result = callback(child_size, parent_rect, work_area);
  if (result == nullptr) {
    return false;
  }
  *out = *result;
  free(result);
  return true;
}

void OHOSWindow::RequestWindowHost()
{
  if (host_kind_ == WindowHostKind::kUiAbility) {
    RequestUiAbilityHost();
    return;
  }
  auto facade = controller_->GetNapiFacade();
  if (!facade) {
    FML_LOG(ERROR) << "RequestWindowHost: no napi facade for view " << view_id_;
    return;
  }
  double width = 0.0;
  double height = 0.0;
  GetSubWindowBirthSize(width, height);
  facade->RequestWindowHost(view_id_, parent_view_id_, width, height, title_,
                            static_cast<int32_t>(type_));
}

void OHOSWindow::GetSubWindowBirthSize(double& width, double& height) const
{
  width = 0;
  height = 0;
  if (request_.has_size) {
    width = request_.size.width;
    height = request_.size.height;
    return;
  }
  if (!request_.has_constraints) {
    return;
  }
  width = request_.constraints.min_width;
  height = request_.constraints.min_height;
}

void OHOSWindow::RequestUiAbilityHost() const
{
  auto facade = controller_->GetNapiFacade();
  if (!facade) {
    FML_LOG(ERROR) << "RequestWindowHost: no napi facade for view " << view_id_;
    return;
  }
  double width = 0.0;
  double height = 0.0;
  if (request_.has_size) {
    width = request_.size.width;
    height = request_.size.height;
  }
  if (view_id_ == static_cast<int64_t>(kFlutterImplicitViewId)) {
    facade->BindEntryAbilityToView(view_id_, width, height, title_);
    return;
  }
  facade->CreateRegularAbility(view_id_, /*request_id=*/view_id_, width, height,
                               title_, static_cast<int32_t>(type_));
}

}  // namespace flutter
