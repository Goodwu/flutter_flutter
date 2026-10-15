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
class OHOSWindow {
 public:
  OHOSWindow(int64_t view_id, const RegularWindowCreationRequest& request);
  OHOSWindow(int64_t view_id, const DialogWindowCreationRequest& request);
  OHOSWindow(int64_t view_id, const TooltipWindowCreationRequest& request);
  OHOSWindow(int64_t view_id, const PopupWindowCreationRequest& request);
  ~OHOSWindow();

  int64_t view_id() const { return view_id_; }

  // Fires the Dart close/notify callbacks; called by the controller while the
  // window is still registered. Each is null-guarded.
  void FireShouldClose();
  void FireWillClose();
  void FireNotifyListeners();

  // Invokes the positioner Dart callback to compute an anchored sub-window's position
  bool ComputeWindowPosition(const WindowSize& child_size,
                             const WindowRect& parent_rect,
                             const WindowRect& work_area,
                             WindowRect* out);

  // Preferred content size from the creation request (LOGICAL px) — the
  // GetContentSize fallback before any actual size has been pushed.
  // Tooltip/popup carry none (their birth size comes from the min constraints).
  bool HasPreferredSize() const { return has_preferred_size_; }
  WindowSize PreferredSize() const { return preferred_size_; }

  // Current-title cache (see the controller's SetTitle/GetTitle): C++ cannot
  // query the OS window title synchronously across napi, so the last pushed
  // value — seeded with the creation title — lives here.
  void SetTitleCache(std::string title) { title_cache_ = std::move(title); }
  const std::string& GetTitle() const { return title_cache_; }

 private:
  explicit OHOSWindow(int64_t view_id);

  int64_t view_id_;
  WindowLifecycleCallbacks callbacks_ = {};
  GetWindowPositionCallback on_get_window_position_ = nullptr;
  bool has_preferred_size_ = false;
  WindowSize preferred_size_ = {};
  std::string title_cache_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_OHOS_WINDOWING_OHOS_WINDOW_H_
