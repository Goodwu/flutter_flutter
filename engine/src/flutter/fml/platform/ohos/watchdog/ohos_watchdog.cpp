/*
 * Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */
#include "ohos_watchdog.h"
#include <hicollie/hicollie.h>
#include <algorithm>
#include <functional>
#include <mutex>

#include "flutter/fml/logging.h"
#include "flutter/fml/make_copyable.h"
#include "flutter/fml/memory/weak_ptr.h"
#include "flutter/fml/trace_event.h"

namespace fml {

namespace OhosWatchdog {

constexpr int resetRatio = 2;
constexpr std::chrono::seconds checkIntervalTime{3};

FlutterWatchdog::FlutterWatchdog(
    fml::RefPtr<fml::TaskRunner> task_runner,
    std::function<std::chrono::steady_clock::time_point()> now)
    : m_task_runner(std::move(task_runner)), m_now(std::move(now)) {
  FML_DLOG(INFO) << "FlutterWatchdog: task_queue_id="
                 << m_task_runner->GetTaskQueueId();
}

void FlutterWatchdog::handleThreadAliveNotification() {
  TRACE_EVENT_INSTANT0("flutter", "feedFlutterWatchdog");
  m_thread_is_alive.store(true);
}

void FlutterWatchdog::runHiCollieStuckDetectionTask() {
  TRACE_EVENT_INSTANT0("flutter", "runHiCollieStuckDetectionTask");
  if (m_thread_is_alive.exchange(false)) {
    m_need_report = true;
    m_is_six_second_event = false;
  } else {
    if (!m_need_report) {
      return;
    }
    FML_LOG(ERROR)
        << "FlutterWatchdog: Monitored thread is not alive, task_queue_id="
        << m_task_runner->GetTaskQueueId();
    reportStuckEvent();
  }

  fml::TaskRunner::RunNowOrPostTask(
      m_task_runner, fml::MakeCopyable([weak_this = weak_from_this()]() {
        auto flutterWatchdog = weak_this.lock();
        if (!flutterWatchdog) {
          return;
        }
        flutterWatchdog->handleThreadAliveNotification();
      }));

  auto now = m_now();
  if ((now - m_lastWatchTime) >= (checkIntervalTime / resetRatio)) {
    m_lastWatchTime = now;
  }

  return;
}

void FlutterWatchdog::reportStuckEvent() {
  auto now = m_now();
  auto timeDelta = now - m_lastWatchTime;
  // Skip reports when the callback interval is outside the expected bounds.
  if (timeDelta / resetRatio > checkIntervalTime ||
      timeDelta < checkIntervalTime / resetRatio) {
    FML_LOG(ERROR)
        << "FlutterWatchdog: Thread may be blocked, do not report this "
           "time."
        << "currTime: "
        << std::chrono::duration<double>(now.time_since_epoch()).count()
        << ", lastTime: "
        << std::chrono::duration<double>(m_lastWatchTime.time_since_epoch())
               .count()
        << ", task_queue_id: " << m_task_runner->GetTaskQueueId();
    return;
  }

  // Suppress further reports until a heartbeat confirms thread recovery.
  if (!m_need_report) {
    return;
  }

  if (m_is_six_second_event) {
    m_need_report = false;
  }

  FML_LOG(WARNING) << "FlutterWatchdog: calling OH_HiCollie_Report(), "
                      "m_is_six_second_event = "
                   << m_is_six_second_event
                   << ", task_queue_id = " << m_task_runner->GetTaskQueueId();

  // HiCollie updates this flag after reporting the 3s warning or 6s freeze.
  HiCollie_ErrorCode reportRes = OH_HiCollie_Report(&m_is_six_second_event);
  if (reportRes == HICOLLIE_SUCCESS) {
    FML_LOG(INFO) << "FlutterWatchdog: OH_HiCollie_Report() success, "
                  << "m_is_six_second_event = " << m_is_six_second_event
                  << ", task_queue_id = " << m_task_runner->GetTaskQueueId();
  } else {
    FML_LOG(ERROR) << "FlutterWatchdog: OH_HiCollie_Report() failed with code "
                   << static_cast<int>(reportRes);
  }
}

size_t RunWithFlutterWatchdogSharedPtr(
    const std::function<void(std::vector<std::shared_ptr<FlutterWatchdog>>&)>&
        runFunc) {
  static std::mutex runMutex;
  static std::vector<std::shared_ptr<FlutterWatchdog>> flutterWatchdogVec;

  {
    std::lock_guard<std::mutex> runLock(runMutex);
    runFunc(flutterWatchdogVec);
    return flutterWatchdogVec.size();
  }
}

std::pair<size_t, std::function<void(size_t)>> MakeWatchdog(
    const fml::RefPtr<fml::TaskRunner>& task_runner,
    std::function<std::chrono::steady_clock::time_point()> now) {
  HiCollie_ErrorCode stuckDetectionInitRes = HICOLLIE_SUCCESS;
  size_t curSize = RunWithFlutterWatchdogSharedPtr(
      [task_runner, &stuckDetectionInitRes, &now](auto& flutterWatchdogVec) {
        // HiCollie has one process-wide callback and TID. Additional threads
        // must not replace that registration or restart its detection timer.
        const bool noLiveThreads = std::all_of(
            flutterWatchdogVec.begin(), flutterWatchdogVec.end(),
            [](const auto& watchdog) { return watchdog == nullptr; });
        if (noLiveThreads) {
          stuckDetectionInitRes = OH_HiCollie_Init_StuckDetection([]() {
            RunWithFlutterWatchdogSharedPtr([](auto& watchdogs) {
              for (const auto& watchdog : watchdogs) {
                if (watchdog) {
                  watchdog->runHiCollieStuckDetectionTask();
                }
              }
            });
          });
        }
        if (stuckDetectionInitRes == HICOLLIE_SUCCESS) {
          flutterWatchdogVec.emplace_back(
              std::make_shared<FlutterWatchdog>(task_runner, std::move(now)));
        }
      });

  if (stuckDetectionInitRes != HICOLLIE_SUCCESS) {
    FML_LOG(ERROR) << "FlutterWatchdog: OH_HiCollie_Init_StuckDetection() "
                      "failed with code "
                   << static_cast<int>(stuckDetectionInitRes);
    return {0, {}};
  }

  std::function<void(size_t)> handlePtr = [](size_t index) {
    RunWithFlutterWatchdogSharedPtr([index](auto& flutterWatchdogVec) {
      if (index >= flutterWatchdogVec.size()) {
        return;
      }
      flutterWatchdogVec[index].reset();
    });
  };

  return make_pair(curSize, handlePtr);
}

}  // namespace OhosWatchdog
}  // namespace fml
