#!/bin/bash
# Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE_HW file.
#
# Build the upload artifact set on a Windows x64 host: 6 targeted gn+ninja
# jobs in parallel (the host builds go through ./ohos, the single source of
# truth for host gn args; the ohos_* variants call gn.bat + ninja directly
# so targeted ninja goals can be passed instead of "default"):
#   host_release            -> default (host tools + dart-sdk for upload)
#   host_debug              -> flutter/lib/snapshot:generate_snapshot_bin only
#   ohos_{release,profile}_{arm64,x64}
#                           -> flutter/build/archives:archive_win_gen_snapshot
#                              only (gen_snapshot.exe per OHOS variant)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/windows_common.sh"

# Steps run with cwd=work_dir; gn.bat / ninja run from the engine root.
cd "$ENGINE_DIR" || exit 1
init_log_dir

GN="src/flutter/tools/gn.bat"
OHOS_ARGS="--no-goma --no-prebuilt-dart-sdk --full-dart-sdk --embedder-for-target --disable-desktop-embeddings --no-build-embedder-examples --ohos-api-int 13 --verbose"

pids=()
names=()

# Run a whole build command in the background, logging to build.<name>.log.
launch_cmd() {
    local name="$1"
    shift
    local log="$LOG_DIR/build.${name}.log"
    log_info "start: ${name} (log: ${log})"
    ( "$@" ) >"$log" 2>&1 &
    pids+=("$!")
    names+=("$name")
}

# host_release / host_debug go through ./ohos (ohos.py), keeping the host gn
# args in one place; --ninja-target restricts host_debug to the snapshot
# target instead of the full default (issue #3034).
launch_cmd host_release ./ohos -t release -n host
launch_cmd host_debug ./ohos -t debug -n host \
    --ninja-target flutter/lib/snapshot:generate_snapshot_bin

# The ohos_* targets keep invoking gn.bat directly: engineConfig() in
# ohos.py would first need an OHOS SDK layout via getNdkHome(), which the
# windows runner environment does not provide.
launch_build() {
    local name="$1" out="$2" target="$3"
    shift 3
    local log="$LOG_DIR/build.${name}.log"
    log_info "start: ${name} (log: ${log})"
    (
        "./$GN" "$@" &&
        ninja -C "src/out/${out}" ${target:+"$target"}
    ) >"$log" 2>&1 &
    pids+=("$!")
    names+=("$name")
}

launch_build ohos_release_arm64   ohos_release_arm64   flutter/build/archives:archive_win_gen_snapshot \
    --ohos --ohos-cpu arm64 --runtime-mode release $OHOS_ARGS
launch_build ohos_profile_arm64   ohos_profile_arm64   flutter/build/archives:archive_win_gen_snapshot \
    --ohos --ohos-cpu arm64 --runtime-mode profile $OHOS_ARGS
launch_build ohos_release_x64     ohos_release_x64     flutter/build/archives:archive_win_gen_snapshot \
    --ohos --ohos-cpu x64 --runtime-mode release $OHOS_ARGS
launch_build ohos_profile_x64     ohos_profile_x64     flutter/build/archives:archive_win_gen_snapshot \
    --ohos --ohos-cpu x64 --runtime-mode profile $OHOS_ARGS

rc=0
for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
        rc=1
        log_error "build failed: ${names[$i]} (see $LOG_DIR/build.${names[$i]}.log)"
    fi
done
if [[ $rc -ne 0 ]]; then
    log_error "build failed (logs under $LOG_DIR)"
    exit 1
fi
log_info "build done (logs: $LOG_DIR)"
