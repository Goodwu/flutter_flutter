/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

#include "flutter/fml/platform/ohos/watchdog/ohos_watchdog.h"

#include <hicollie/hicollie.h>

#include <atomic>
#include <chrono>
#include <limits>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#include "flutter/fml/message_loop_impl.h"
#include "flutter/fml/synchronization/waitable_event.h"
#include "flutter/fml/thread.h"
#include "gtest/gtest.h"

namespace {

struct FakeHiCollie {
  std::mutex mutex;
  HiCollie_ErrorCode init_result = HICOLLIE_SUCCESS;
  OH_HiCollie_Task task = nullptr;
  std::function<void()> before_report;
  std::vector<bool> reports;
  std::thread::id registration_thread;
  std::thread::id report_thread;
  size_t init_calls = 0;
};

FakeHiCollie hicollie;

}  // namespace

// Keep these stubs in a separate test executable, never in the engine.
extern "C" HiCollie_ErrorCode OH_HiCollie_Init_StuckDetection(
    OH_HiCollie_Task task) {
  std::lock_guard<std::mutex> lock(hicollie.mutex);
  hicollie.init_calls++;
  hicollie.registration_thread = std::this_thread::get_id();
  if (hicollie.init_result == HICOLLIE_SUCCESS) {
    hicollie.task = task;
  }
  return hicollie.init_result;
}

extern "C" HiCollie_ErrorCode OH_HiCollie_Report(bool* is_six_second) {
  const bool six_second = *is_six_second;
  std::function<void()> before_report;
  {
    std::lock_guard<std::mutex> lock(hicollie.mutex);
    hicollie.reports.push_back(six_second);
    hicollie.report_thread = std::this_thread::get_id();
    before_report = hicollie.before_report;
  }
  if (before_report) {
    before_report();
  }
  EXPECT_EQ(*is_six_second, six_second);
  *is_six_second = !six_second;
  return HICOLLIE_SUCCESS;
}

namespace fml {
namespace OhosWatchdog {
namespace {

constexpr int kHeartbeatCheckIterations = 1000;
constexpr int kStuckRasterCheckCount = 3;
constexpr std::chrono::seconds kWatchdogCheckInterval{3};
constexpr std::chrono::seconds kMaxCallbackInterval{6};
constexpr std::chrono::steady_clock::duration kLateCallbackOffset{2};

class FeedTaskRunner : public fml::TaskRunner {
 public:
  FeedTaskRunner() : TaskRunner(nullptr) {}
  void PostTask(const fml::closure& task) override {
    std::lock_guard<std::mutex> lock(mutex_);
    tasks_.push_back(task);
  }
  bool RunsTasksOnCurrentThread() override { return false; }
  fml::TaskQueueId GetTaskQueueId() override { return fml::TaskQueueId(1); }
  size_t PendingTasks() {
    std::lock_guard<std::mutex> lock(mutex_);
    return tasks_.size() - next_task_;
  }

  void RunPendingTasks() {
    std::vector<fml::closure> tasks;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (; next_task_ < tasks_.size(); next_task_++) {
        tasks.push_back(tasks_[next_task_]);
      }
    }
    for (const auto& task : tasks) {
      task();
    }
  }

 private:
  std::mutex mutex_;
  // Retain tasks until both test threads stop, isolating state races from
  // FML's acquire-fence reference-count destruction in partial TSan builds.
  std::vector<fml::closure> tasks_;
  size_t next_task_ = 0;
};

class OhosWatchdogTest : public ::testing::Test {
 protected:
  using Handle = std::pair<size_t, std::function<void(size_t)>>;

  void SetUp() override {
    now_ = std::chrono::steady_clock::time_point(std::chrono::hours(1));
    std::lock_guard<std::mutex> lock(hicollie.mutex);
    hicollie.init_result = HICOLLIE_SUCCESS;
    hicollie.task = nullptr;
    hicollie.before_report = nullptr;
    hicollie.reports.clear();
    hicollie.registration_thread = {};
    hicollie.report_thread = {};
    hicollie.init_calls = 0;
  }

  void TearDown() override {
    for (const auto& handle : handles_) {
      if (handle.first != 0 && handle.second) {
        handle.second(handle.first - 1);
      }
    }
  }

  Handle Watch(const fml::RefPtr<fml::TaskRunner>& runner) {
    auto handle = MakeWatchdog(runner, [this] { return now_; });
    EXPECT_NE(handle.first, 0u);
    EXPECT_TRUE(handle.second);
    handles_.push_back(handle);
    return handle;
  }

  void Check() {
    OH_HiCollie_Task task;
    {
      std::lock_guard<std::mutex> lock(hicollie.mutex);
      task = hicollie.task;
    }
    ASSERT_NE(task, nullptr);
    task();
  }

  void CheckAfterInterval() {
    now_ += kWatchdogCheckInterval;
    Check();
  }

  std::vector<bool> Reports() {
    std::lock_guard<std::mutex> lock(hicollie.mutex);
    return hicollie.reports;
  }

  // Only the monitor reads or advances fake time, including concurrency tests.
  std::chrono::steady_clock::time_point now_;
  std::vector<Handle> handles_;
};

TEST_F(OhosWatchdogTest, InitializationFailureCanRetryWithoutInvalidIndex) {
  auto runner = fml::MakeRefCounted<FeedTaskRunner>();
  hicollie.init_result = HICOLLIE_WRONG_THREAD_CONTEXT;
  auto failed = MakeWatchdog(runner);
  EXPECT_EQ(failed.first, 0u);
  EXPECT_FALSE(failed.second);

  hicollie.init_result = HICOLLIE_SUCCESS;
  Watch(runner);
  Check();
  EXPECT_EQ(runner->PendingTasks(), 1u);
}

TEST_F(OhosWatchdogTest, CleanupRejectsOutOfRangeIndices) {
  auto runner = fml::MakeRefCounted<FeedTaskRunner>();
  auto handle = Watch(runner);
  handle.second(handle.first);
  handle.second(std::numeric_limits<size_t>::max());
  Check();
  EXPECT_EQ(runner->PendingTasks(), 1u);

  handle.second(handle.first - 1);
  handle.second(handle.first - 1);
  runner->RunPendingTasks();
  Check();
  EXPECT_EQ(runner->PendingTasks(), 0u);
}

TEST_F(OhosWatchdogTest, ChecksEveryLiveRasterAfterNewestIsDestroyed) {
  auto first = fml::MakeRefCounted<FeedTaskRunner>();
  auto newest = fml::MakeRefCounted<FeedTaskRunner>();
  Watch(first);
  auto handle = Watch(newest);
  Check();
  EXPECT_EQ(first->PendingTasks(), 1u);
  EXPECT_EQ(newest->PendingTasks(), 1u);

  handle.second(handle.first - 1);
  first->RunPendingTasks();
  newest->RunPendingTasks();
  Check();
  EXPECT_EQ(first->PendingTasks(), 1u);
  EXPECT_EQ(newest->PendingTasks(), 0u);
}

TEST_F(OhosWatchdogTest, LiveRastersShareRegistrationAndRetryAfterCleanup) {
  auto first = fml::MakeRefCounted<FeedTaskRunner>();
  auto second = fml::MakeRefCounted<FeedTaskRunner>();
  auto first_handle = Watch(first);
  auto second_handle = Watch(second);
  EXPECT_EQ(hicollie.init_calls, 1u);

  first_handle.second(first_handle.first - 1);
  auto third = fml::MakeRefCounted<FeedTaskRunner>();
  auto third_handle = Watch(third);
  EXPECT_EQ(hicollie.init_calls, 1u);
  Check();
  EXPECT_EQ(first->PendingTasks(), 0u);
  EXPECT_EQ(second->PendingTasks(), 1u);
  EXPECT_EQ(third->PendingTasks(), 1u);

  second_handle.second(second_handle.first - 1);
  third_handle.second(third_handle.first - 1);
  Watch(first);
  EXPECT_EQ(hicollie.init_calls, 2u);
  Check();
  EXPECT_EQ(first->PendingTasks(), 1u);
}

TEST_F(OhosWatchdogTest, ConcurrentRastersDoNotReplaceRegistration) {
  auto first = fml::MakeRefCounted<FeedTaskRunner>();
  auto second = fml::MakeRefCounted<FeedTaskRunner>();
  Handle first_handle;
  Handle second_handle;
  fml::ManualResetWaitableEvent start;
  std::thread first_raster([&start, &first_handle, &first] {
    start.Wait();
    first_handle = MakeWatchdog(first);
  });
  std::thread second_raster([&start, &second_handle, &second] {
    start.Wait();
    second_handle = MakeWatchdog(second);
  });
  start.Signal();
  first_raster.join();
  second_raster.join();
  handles_.push_back(first_handle);
  handles_.push_back(second_handle);
  ASSERT_NE(first_handle.first, 0u);
  ASSERT_NE(second_handle.first, 0u);
  EXPECT_NE(first_handle.first, second_handle.first);
  EXPECT_EQ(hicollie.init_calls, 1u);
  Check();
  EXPECT_EQ(first->PendingTasks(), 1u);
  EXPECT_EQ(second->PendingTasks(), 1u);
}

TEST_F(OhosWatchdogTest, HealthyRasterDoesNotReport) {
  auto runner = fml::MakeRefCounted<FeedTaskRunner>();
  Watch(runner);
  Check();
  for (int i = 0; i < kHeartbeatCheckIterations; i++) {
    ASSERT_EQ(runner->PendingTasks(), 1u);
    runner->RunPendingTasks();
    CheckAfterInterval();
  }
  EXPECT_TRUE(Reports().empty());
}

TEST_F(OhosWatchdogTest, ReportsThreeThenSixSecondsAndRearmsAfterRecovery) {
  auto runner = fml::MakeRefCounted<FeedTaskRunner>();
  Watch(runner);
  Check();
  CheckAfterInterval();
  CheckAfterInterval();
  Check();
  EXPECT_EQ(Reports(), (std::vector<bool>{false, true}));

  runner->RunPendingTasks();
  Check();
  CheckAfterInterval();
  CheckAfterInterval();
  EXPECT_EQ(Reports(), (std::vector<bool>{false, true, false, true}));
}

TEST_F(OhosWatchdogTest, EarlyCallbacksDoNotResetTheMinimumInterval) {
  auto runner = fml::MakeRefCounted<FeedTaskRunner>();
  Watch(runner);
  Check();
  EXPECT_TRUE(Reports().empty());

  // The existing seconds-based interval / 2 truncates to one second.
  now_ += std::chrono::seconds(1) - std::chrono::nanoseconds(1);
  Check();
  EXPECT_TRUE(Reports().empty());
  now_ += std::chrono::nanoseconds(1);
  Check();
  EXPECT_EQ(Reports(), (std::vector<bool>{false}));
}

TEST_F(OhosWatchdogTest, LateCallbackSkipsReportAndResetsTheTimingWindow) {
  auto runner = fml::MakeRefCounted<FeedTaskRunner>();
  Watch(runner);
  Check();

  // Use two clock ticks so division by two remains above the upper bound.
  now_ += kMaxCallbackInterval + kLateCallbackOffset;
  Check();
  EXPECT_TRUE(Reports().empty());
  CheckAfterInterval();
  EXPECT_EQ(Reports(), (std::vector<bool>{false}));

  now_ += kMaxCallbackInterval;
  Check();
  EXPECT_EQ(Reports(), (std::vector<bool>{false, true}));
  CheckAfterInterval();
  EXPECT_EQ(Reports(), (std::vector<bool>{false, true}));
}

class MultipleRastersTest : public OhosWatchdogTest,
                            public ::testing::WithParamInterface<bool> {};

TEST_P(MultipleRastersTest, HealthyRasterDoesNotMaskStuckRaster) {
  auto stuck = fml::MakeRefCounted<FeedTaskRunner>();
  auto healthy = fml::MakeRefCounted<FeedTaskRunner>();
  if (GetParam()) {
    Watch(stuck);
    Watch(healthy);
  } else {
    Watch(healthy);
    Watch(stuck);
  }
  Check();
  for (int i = 0; i < kStuckRasterCheckCount; i++) {
    healthy->RunPendingTasks();
    CheckAfterInterval();
  }
  EXPECT_EQ(Reports(), (std::vector<bool>{false, true}));
}

INSTANTIATE_TEST_SUITE_P(RegistrationOrder,
                         MultipleRastersTest,
                         ::testing::Bool());

TEST_F(OhosWatchdogTest, RegistersAndPostsHeartbeatsOnRasterThread) {
  fml::Thread raster("watchdog.raster");
  auto runner = raster.GetTaskRunner();
  fml::AutoResetWaitableEvent initialized;
  runner->PostTask([this, &runner, &initialized] {
    EXPECT_TRUE(runner->RunsTasksOnCurrentThread());
    Watch(runner);
    EXPECT_EQ(hicollie.registration_thread, std::this_thread::get_id());
    initialized.Signal();
  });
  initialized.Wait();
  EXPECT_NE(hicollie.registration_thread, std::this_thread::get_id());

  Check();
  fml::AutoResetWaitableEvent drained;
  runner->PostTask([&drained] { drained.Signal(); });
  drained.Wait();
  Check();
  raster.Join();
  EXPECT_TRUE(Reports().empty());
}

TEST_F(OhosWatchdogTest, RasterHeartbeatCanRunWhileMonitorReports) {
  auto runner = fml::MakeRefCounted<FeedTaskRunner>();
  fml::AutoResetWaitableEvent initialized;
  std::atomic<bool> stop{false};
  std::thread raster([this, &runner, &initialized, &stop] {
    Watch(runner);
    initialized.Signal();
    while (!stop.load()) {
      runner->RunPendingTasks();
      std::this_thread::yield();
    }
  });
  initialized.Wait();

  std::atomic<bool> drained{false};
  Check();
  for (int i = 0; i < kHeartbeatCheckIterations; i++) {
    Check();
  }
  runner->PostTask([&drained] { drained.store(true); });
  while (!drained.load()) {
    Check();
  }
  Check();

  fml::AutoResetWaitableEvent blocked;
  fml::AutoResetWaitableEvent release;
  runner->PostTask([&blocked, &release] {
    blocked.Signal();
    release.Wait();
  });
  blocked.Wait();
  // Consume any last heartbeat, then queue another behind the blocked task.
  Check();
  CheckAfterInterval();
  EXPECT_EQ(Reports(), (std::vector<bool>{false}));
  fml::AutoResetWaitableEvent heartbeat_drained;
  hicollie.before_report = [&release, &runner, &heartbeat_drained] {
    release.Signal();
    runner->PostTask([&heartbeat_drained] { heartbeat_drained.Signal(); });
    heartbeat_drained.Wait();
  };
  CheckAfterInterval();
  EXPECT_EQ(Reports(), (std::vector<bool>{false, true}));
  EXPECT_EQ(hicollie.report_thread, std::this_thread::get_id());
  EXPECT_NE(hicollie.report_thread, hicollie.registration_thread);
  release.Signal();
  stop.store(true);
  raster.join();
}

}  // namespace
}  // namespace OhosWatchdog
}  // namespace fml
