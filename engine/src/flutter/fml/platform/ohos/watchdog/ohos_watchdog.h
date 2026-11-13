/*
 * Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */
#ifndef FLUTTER_FML_PLATFORM_OHOS_WATCHDOG_OHOS_WATCHDOG_H_
#define FLUTTER_FML_PLATFORM_OHOS_WATCHDOG_OHOS_WATCHDOG_H_

#include <atomic>
#include <chrono>
#include <functional>
#include <memory>
#include <utility>
#include "flutter/fml/task_runner.h"

namespace fml {

namespace OhosWatchdog {

class FlutterWatchdog : public std::enable_shared_from_this<FlutterWatchdog> {
 public:
  FlutterWatchdog(fml::RefPtr<fml::TaskRunner> task_runner,
                  std::function<std::chrono::steady_clock::time_point()> now);

  void runHiCollieStuckDetectionTask();
  void handleThreadAliveNotification();
  void reportStuckEvent();

 private:
  // The monitored thread publishes liveness; only HiCollie's monitor changes
  // report state.
  std::atomic<bool> m_thread_is_alive{false};
  bool m_need_report = true;
  bool m_is_six_second_event = false;

  std::chrono::steady_clock::time_point m_lastWatchTime;
  fml::RefPtr<fml::TaskRunner> m_task_runner;
  const std::function<std::chrono::steady_clock::time_point()> m_now;
};

// Call on the monitored thread. All live watchdogs share HiCollie's
// process-wide registration, whose reported TID belongs to the first registered
// thread, not necessarily the blocked one. The optional clock runs on
// HiCollie's monitor; it defaults to real time.
std::pair<size_t, std::function<void(size_t)>> MakeWatchdog(
    const fml::RefPtr<fml::TaskRunner>& task_runner,
    std::function<std::chrono::steady_clock::time_point()> now =
        std::chrono::steady_clock::now);

}  // namespace OhosWatchdog
}  // namespace fml
#endif  // FLUTTER_FML_PLATFORM_OHOS_WATCHDOG_OHOS_WATCHDOG_H_
