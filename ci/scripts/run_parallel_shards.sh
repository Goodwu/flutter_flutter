#!/bin/bash
# Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE_HW file.

# Single-machine staggered parallel shard scheduler for OHOS CI.
#
# Strategy: launch heavy shards first, then stagger lightweight shards
# after a delay. This avoids the initial resource contention that occurs
# when 14+ flutter test processes all start compiling simultaneously.
#
# Wave 1 (t=0):  Heavy framework subshards (libraries x3, widgets x3)
# Wave 2 (t=2m): Medium shards (misc, misc2, widget_extras, tool_tests_commands)
# Wave 3 (t=4m): Light shards (slow, general, snippets, host_cross_arch)
#
# Wave 1 shards run with --coverage; after all shards finish, the shard lcov
# files are merged into a summary report (lcov.info + HTML), as on
# oh-3.35.7-dev.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_ROOT="$SCRIPT_DIR/../.."

export OHOS_CI=true
export PUB_CACHE="${PUB_CACHE:-$WORK_DIR/pub_cache_shared}"

LOG_DIR="$WORK_DIR/Archive/out/unit_tests_logs"
mkdir -p "$LOG_DIR"

# --- Helper: launch a shard ---

declare -A SHARD_PIDS
declare -A SHARD_LABELS

launch_shard() {
    local shard="$1"
    local subshard="${2:-}"
    local extra_env="${3:-}"
    local extra_args="${4:-}"

    env_label=""
    env_export=""
    if [ -n "$extra_env" ]; then
        env_export="$extra_env"
        env_label="_${extra_env#*=}"
    fi

    if [ -n "$subshard" ]; then
        label="${shard}_${subshard}${env_label}"
    else
        label="${shard}_all"
    fi

    if [ -n "$subshard" ]; then
        env $env_export bash "$SCRIPT_DIR/run_shard_test.sh" "$shard" "$subshard" $extra_args &
    else
        env $env_export bash "$SCRIPT_DIR/run_shard_test.sh" "$shard" $extra_args &
    fi
    pid=$!
    SHARD_PIDS[$label]=$pid
    SHARD_LABELS[$pid]=$label
    echo "[$(date +%H:%M:%S)] START: $label (pid=$pid)"
}

# --- Wave 1: Heavy shards (t=0) ---
# These are the longest-running shards. Start them first to maximize
# parallel overlap with shorter shards that start later.

echo "[$(date +%H:%M:%S)] Wave 1: Launching heavy framework shards"

launch_shard framework_tests libraries "OHOS_LIBRARIES_SUBSHARD=1_3" "--coverage --coverage-path=coverage/lcov_libraries_1_3.info"
launch_shard framework_tests libraries "OHOS_LIBRARIES_SUBSHARD=2_3" "--coverage --coverage-path=coverage/lcov_libraries_2_3.info"
launch_shard framework_tests libraries "OHOS_LIBRARIES_SUBSHARD=3_3" "--coverage --coverage-path=coverage/lcov_libraries_3_3.info"
launch_shard framework_tests libraries "OHOS_LIBRARIES_SUBSHARD=non_material OHOS_NON_MATERIAL_SUBSHARD=1_2" "--coverage --coverage-path=coverage/lcov_libraries_non_material_1_2.info"
launch_shard framework_tests libraries "OHOS_LIBRARIES_SUBSHARD=non_material OHOS_NON_MATERIAL_SUBSHARD=2_2" "--coverage --coverage-path=coverage/lcov_libraries_non_material_2_2.info"
launch_shard framework_tests widgets   "OHOS_WIDGETS_SUBSHARD=1_3" "--coverage --coverage-path=coverage/lcov_widgets_1_3.info"
launch_shard framework_tests widgets   "OHOS_WIDGETS_SUBSHARD=2_3" "--coverage --coverage-path=coverage/lcov_widgets_2_3.info"
launch_shard framework_tests widgets   "OHOS_WIDGETS_SUBSHARD=3_3" "--coverage --coverage-path=coverage/lcov_widgets_3_3.info"

# --- Wave 2: Medium shards (t=2min) ---
# Wait 2 minutes for the heavy shards to finish their initial compilation
# and pub resolution, then start the medium-weight shards.

sleep 120

echo "[$(date +%H:%M:%S)] Wave 2: Launching medium shards"

launch_shard analyze
launch_shard framework_tests misc
launch_shard framework_tests misc2
launch_shard framework_tests misc3
launch_shard framework_tests widget_extras
launch_shard tool_tests_commands

# --- Wave 3: Light shards (t=4min) ---
# Another 2-minute delay, then start the lightest shards that finish
# in seconds to minutes. By this time the heavy shards are deep into
# test execution and no longer competing for compilation resources.

sleep 120

echo "[$(date +%H:%M:%S)] Wave 3: Launching light shards"

launch_shard framework_tests slow
launch_shard tool_tests general
launch_shard snippets
launch_shard tool_host_cross_arch_tests

# --- Wait for all shards ---

FAILED_SHARDS=()
PASSED_SHARDS=()

for label in "${!SHARD_PIDS[@]}"; do
    pid=${SHARD_PIDS[$label]}
    if wait $pid; then
        PASSED_SHARDS+=("$label")
    else
        FAILED_SHARDS+=("$label")
    fi
done

# --- Merge sharded coverage data & generate HTML report ---

# Ensure lcov (provides lcov + genhtml) is available; install if missing.
ensure_lcov() {
    if command -v genhtml >/dev/null 2>&1 && command -v lcov >/dev/null 2>&1; then
        return 0
    fi
    echo "[$(date +%H:%M:%S)] lcov not found, attempting installation..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq 2>/dev/null || true
        apt-get install -y lcov
    else
        echo "[$(date +%H:%M:%S)] WARN: apt-get not available, cannot install lcov"
        return 1
    fi
}

COVERAGE_DIR="$FLUTTER_ROOT/packages/flutter/coverage"
LCOV_FILES=()
if [ -d "$COVERAGE_DIR" ]; then
    for f in "$COVERAGE_DIR"/lcov_*.info; do
        [ -f "$f" ] && LCOV_FILES+=("$f")
    done
fi

if [ ${#LCOV_FILES[@]} -gt 0 ]; then
    mkdir -p "$LOG_DIR/reports"
    MERGED_LCOV="$COVERAGE_DIR/lcov.info"
    ensure_lcov
    if command -v lcov >/dev/null 2>&1; then
        lcov_args=()
        for f in "${LCOV_FILES[@]}"; do
            lcov_args+=(--add-tracefile "$f")
        done
        lcov "${lcov_args[@]}" --output-file "$MERGED_LCOV" 2>/dev/null \
            || cat "${LCOV_FILES[@]}" > "$MERGED_LCOV"
    else
        cat "${LCOV_FILES[@]}" > "$MERGED_LCOV"
    fi
    cp "$MERGED_LCOV" "$LOG_DIR/reports/lcov.info"
    echo "[$(date +%H:%M:%S)] Coverage: merged ${#LCOV_FILES[@]} file(s) -> $LOG_DIR/reports/lcov.info"

    # Generate HTML report
    HTML_REPORT_DIR="$LOG_DIR/reports/coverage_html"
    if command -v genhtml >/dev/null 2>&1; then
        genhtml "$MERGED_LCOV" -o "$HTML_REPORT_DIR" \
            --no-branch-coverage --ignore-errors source --no-source \
            2>/dev/null && echo "[$(date +%H:%M:%S)] Coverage: HTML report -> $HTML_REPORT_DIR/index.html" \
            || echo "[$(date +%H:%M:%S)] WARN: genhtml failed"
    else
        echo "[$(date +%H:%M:%S)] WARN: genhtml not available, skipping HTML report"
    fi
else
    echo "[$(date +%H:%M:%S)] Coverage: no shard lcov files found"
fi

# --- Summary ---

TOTAL_SHARDS=$((${#PASSED_SHARDS[@]} + ${#FAILED_SHARDS[@]}))

echo ""
echo "=========================================="
echo "  Parallel Shard Test Summary"
echo "=========================================="
echo "  Passed: ${#PASSED_SHARDS[@]} / $TOTAL_SHARDS"
for label in "${PASSED_SHARDS[@]}"; do
    echo "    PASS: $label"
done
if [ ${#FAILED_SHARDS[@]} -gt 0 ]; then
    echo "  Failed: ${#FAILED_SHARDS[@]} / $TOTAL_SHARDS"
    for label in "${FAILED_SHARDS[@]}"; do
        echo "    FAIL: $label"
    done
fi
echo ""

if [ ${#FAILED_SHARDS[@]} -gt 0 ]; then
    echo "  RESULT: FAIL (${#FAILED_SHARDS[@]} shard(s) failed)"
    echo "  Logs: $LOG_DIR"
    echo "  Reports: $LOG_DIR/reports/"
    exit 1
fi

echo "  RESULT: ALL PASSED"
echo "  Reports: $LOG_DIR/reports/"
exit 0
