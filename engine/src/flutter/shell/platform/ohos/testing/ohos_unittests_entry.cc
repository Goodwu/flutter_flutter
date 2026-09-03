/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

#include <cstring>

#include "gtest/gtest.h"

// 当编译为共享库 (.so) 时，没有 main() 入口点。
// 此函数作为 C 导出接口，供 NAPI / dlopen 调用。
//
// 用法:
//   extern "C" int FlutterOhosRunAllTests(int argc, char** argv);
//
// 返回值: 0 表示全部通过，非 0 表示有失败
extern "C" __attribute__((visibility("default"))) int FlutterOhosRunAllTests(
    int argc,
    char** argv) {
  // .so 通过 dlopen 加载后驻留内存，GTEST_FLAG(filter) 是全局静态变量，
  // 上次设置的值会残留。每次调用时先重置为默认值 "*"（全量执行），
  // 再根据 argv 中的 --gtest_filter 参数覆盖。
  testing::GTEST_FLAG(filter) = "*";
  // 手动解析 --gtest_filter，因为 InitGoogleTest 在 .so 中不解析该参数
  for (int i = 1; i < argc; i++) {
    if (argv[i] && strncmp(argv[i], "--gtest_filter=", 15) == 0) {
      testing::GTEST_FLAG(filter) = argv[i] + 15;
    }
  }
  testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}

// ── 覆盖率数据导出封装 ──────────────────────────────────
// __llvm_profile_write_file 是 LLVM profile runtime 的 local 符号，
// stripped .so 删除了 .symtab，dlsym 无法直接查找。
// 这里通过 wrapper 将其导出为全局可见符号，供 dlopen/dlsym 调用。
//
// 用法:
//   extern "C" int FlutterOhosWriteCoverageProfile(const char* filename);
//
// 参数 filename: profraw 输出路径，传 nullptr 则使用 LLVM_PROFILE_FILE 环境变量
// 返回值: 0 成功，非 0 失败
extern "C" __attribute__((visibility("default"))) int
FlutterOhosWriteCoverageProfile(const char* filename) {
  // 声明 LLVM profile runtime 函数（由 libclang_rt.profile.a 提供，仅
  // coverage 构建存在）。弱符号让本 so 在普通（无插桩）构建下也能链接，
  // 此时调用直接返回 -1——测试可正常执行，只是没有覆盖率数据。
  extern int __llvm_profile_write_file(void) __attribute__((weak));
  extern void __llvm_profile_set_filename(const char*) __attribute__((weak));

  if (__llvm_profile_write_file == nullptr ||
      __llvm_profile_set_filename == nullptr) {
    return -1;
  }
  if (filename != nullptr) {
    __llvm_profile_set_filename(filename);
  }
  return __llvm_profile_write_file();
}
