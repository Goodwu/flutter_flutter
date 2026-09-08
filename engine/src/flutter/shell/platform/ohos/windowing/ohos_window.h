/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

#ifndef FLUTTER_SHELL_PLATFORM_OHOS_WINDOWING_OHOS_WINDOW_H_
#define FLUTTER_SHELL_PLATFORM_OHOS_WINDOWING_OHOS_WINDOW_H_

#include <cstdint>
#include <string>
#include <utility>

#include "flutter/shell/platform/ohos/windowing/ohos_window_types.h"

namespace flutter {

class OHOSWindowController;
class PlatformViewOHOSNapi;

class OHOSWindow {
 public:
  struct InitParams {
    WindowType type;
    WindowHostKind host_kind;
    int64_t view_id;
    int64_t parent_view_id;
  };

  OHOSWindow(OHOSWindowController* controller,
             const InitParams& params,
             const FlutterWindowCreationRequest& request);
  ~OHOSWindow();

  WindowType type() const { return type_; }
  WindowHostKind host_kind() const { return host_kind_; }
  int64_t view_id() const { return view_id_; }
  int64_t parent_view_id() const { return parent_view_id_; }
  const FlutterWindowCreationRequest& request() const { return request_; }

  // Fires the Dart close/notify callbacks; called by the controller while the
  // window is still registered.
  void FireShouldClose();
  void FireWillClose();
  void FireNotifyListeners();

  // Invokes the request's on_get_window_position Dart callback to compute an
  // anchored sub-window's position. Called synchronously from the ETS
  // host (nativeComputeWindowPosition napi bridge) once createSubWindow has
  // resolved the parent geometry. All coordinates are LOGICAL px, including
  // `out`. Returns false (caller's placement untouched) when no positioner is
  // present. The callback returns a Dart-side calloc'd FlutterWindowRect*;
  // values are copied into `out` and the pointer free()'d here.
  bool ComputeWindowPosition(const FlutterWindowSize& child_size,
                             const FlutterWindowRect& parent_rect,
                             const FlutterWindowRect& work_area,
                             FlutterWindowRect* out);

  void RequestWindowHost();

  // SubWindow birth size (LOGICAL px): the explicit request size, else the
  // min constraint, else 0x0 (ETS per-type default).
  void GetSubWindowBirthSize(double& width, double& height) const;

  void SetTitleCache(std::string title) { title_ = std::move(title); }
  const std::string& GetTitle() const { return title_; }

 private:
  // UIAbility host request (Regular + modeless Dialog): view 0 adopts the
  // EntryAbility's pre-created window; view 1+ spawns a RegularWindowAbility.
  void RequestUiAbilityHost() const;

  OHOSWindowController* controller_;
  WindowType type_;
  WindowHostKind host_kind_;
  int64_t view_id_;
  int64_t parent_view_id_;
  FlutterWindowCreationRequest request_;

  // See SetTitleCache.
  std::string title_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_OHOS_WINDOWING_OHOS_WINDOW_H_
