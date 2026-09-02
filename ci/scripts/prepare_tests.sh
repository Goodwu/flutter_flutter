#!/bin/bash
# Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE_HW file.
#
# Prepare tests
#
# Clones the test repository, generates config files, and archives the
# tests to the output directory.
# Steps:
#   1. Determines the target branch based on the test purpose.
#   2. Clones the test project from the given URL and branch.
#   3. Creates a resource directory under the tests directory.
#   4. Writes the given flutter version to flutter.version.
#   5. If PR_URL is set, extracts the merge request number and writes it to
#      flutter.pr_no.
#   6. If purpose is "unit", collects:
#        - flutter_ohos_unittests and libflutter.so from the engine build
#          output into resource/gtest/<ohos_variant>/ and resource/
#          respectively.
#        - hello_world flutter_assets into resource/flutter_assets/, and
#          hello_world native .so files (arm64-v8a) into resource/libs/.
#   7. Moves the tests directory into Archive/out for packaging.
#
# Usage: prepare_tests.sh <project_url> <purpose> <flutter_version> [engine_dir]
#   purpose: "unit"        -> branch flutter_UT
#            "integration" -> branch flutter_gate (if PR_URL is set)
#                             branch flutter_daily (if PR_URL is not set)
#   engine_dir: Optional, defaults to "flutter_flutter/engine".
# Environment:
#   PR_URL - Optional. Merge request URL to extract the MR number from.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

prepare_tests() {
    local project_url="$1"
    local purpose="$2"
    local flutter_version="$3"
    local engine_dir="${4:-flutter_flutter/engine}"

    if [[ -z "$project_url" ]]; then
        log_error "project_url is required"
        exit 1
    fi
    if [[ -z "$purpose" ]]; then
        log_error "purpose is required"
        exit 1
    fi
    if [[ -z "$flutter_version" ]]; then
        log_error "flutter_version is required"
        exit 1
    fi

    local target_branch=""
    case "$purpose" in
        unit)
            target_branch="flutter_UT"
            ;;
        integration)
            if [[ -n "$PR_URL" ]]; then
                target_branch="flutter_gate"
            else
                target_branch="flutter_daily"
            fi
            ;;
        *)
            log_error "unknown purpose: $purpose (expected: unit | integration)"
            exit 1
            ;;
    esac

    WORK_DIR=$(pwd)
    PROJECT_DIR="$WORK_DIR/third_party"
    ARCHIVE_DIR="$WORK_DIR/Archive/out"

    local project_name=$(basename "$project_url" .git)

    log_info "Cloning test project: $project_url (branch: $target_branch)"
    cd "$PROJECT_DIR"
    run_cmd "git clone -b $target_branch $project_url"
    cd "$project_name"
    run_cmd "git branch"

    cd "$WORK_DIR"

    local tests_dir="$PROJECT_DIR/tests"
    if [[ ! -d "$tests_dir" ]]; then
        log_error "tests directory not found: $tests_dir"
        exit 1
    fi

    local resource_dir="$tests_dir/resource"
    run_cmd "mkdir -p $resource_dir"

    log_info "Generating config files for tests"

    log_info "flutter.version: $flutter_version"
    echo "$flutter_version" > "$resource_dir/flutter.version"

    local pr_no=""
    if [[ -n "$PR_URL" ]]; then
        pr_no=$(echo "$PR_URL" | grep -oP 'merge_requests/\K[0-9]+')
    fi
    if [[ -n "$pr_no" ]]; then
        log_info "flutter.pr_no: $pr_no"
        echo "$pr_no" > "$resource_dir/flutter.pr_no"
    fi

    if [[ "$purpose" == "unit" ]]; then
        collect_engine_artifacts "$engine_dir" "$resource_dir"
        collect_hello_world_artifacts "$resource_dir"
    fi

    log_info "Moving tests to archive directory"
    run_cmd "mv $PROJECT_DIR/tests $ARCHIVE_DIR/"

    log_info "Tests preparation completed"
}

collect_engine_artifacts() {
    local engine_dir="$1"
    local resource_dir="$2"

    local out_dir="$PROJECT_DIR/$engine_dir/src/out"
    if [[ ! -d "$out_dir" ]]; then
        log_error "engine output directory not found: $out_dir"
        exit 1
    fi

    local build_mode=""
    if [[ -d "$out_dir/host_debug" && -d "$out_dir/host_profile" && -d "$out_dir/host_release" ]]; then
        local modes=("debug" "profile" "release")
        build_mode="${modes[$((RANDOM % 3))]}"
        log_info "Multiple build modes found, randomly selected: $build_mode"
    elif [[ -d "$out_dir/host_release" ]]; then
        build_mode="release"
    elif [[ -d "$out_dir/host_profile" ]]; then
        build_mode="profile"
    elif [[ -d "$out_dir/host_debug" ]]; then
        build_mode="debug"
    else
        log_error "No valid build mode found in $out_dir"
        exit 1
    fi

    local ohos_variant="ohos_${build_mode}_arm64"
    local engine_bin_dir="$out_dir/$ohos_variant"
    local gtest_dir="$resource_dir/gtest/$ohos_variant"

    log_info "Collecting flutter_ohos_unittests from $ohos_variant"

    run_cmd "mkdir -p $gtest_dir/exe.unstripped"

    local unittest_bin="$engine_bin_dir/flutter_ohos_unittests"
    if [[ -f "$unittest_bin" ]]; then
        run_cmd "cp $unittest_bin $gtest_dir/"
    else
        log_error "flutter_ohos_unittests not found: $unittest_bin"
        exit 1
    fi

    local unittest_bin_unstripped="$engine_bin_dir/exe.unstripped/flutter_ohos_unittests"
    if [[ -f "$unittest_bin_unstripped" ]]; then
        run_cmd "cp $unittest_bin_unstripped $gtest_dir/exe.unstripped/"
    else
        log_error "unstripped flutter_ohos_unittests not found: $unittest_bin_unstripped"
        exit 1
    fi

}

collect_hello_world_artifacts() {
    local resource_dir="$1"

    local hello_world_dir="$PROJECT_DIR/flutter_flutter/examples/hello_world"
    if [[ ! -d "$hello_world_dir" ]]; then
        log_error "hello_world directory not found: $hello_world_dir"
        exit 1
    fi

    local assets_src="$hello_world_dir/ohos/entry/src/main/resources/rawfile/flutter_assets"
    if [[ -d "$assets_src" ]]; then
        local assets_dst="$resource_dir/flutter_assets"
        log_info "Collecting hello_world flutter_assets into $assets_dst"
        run_cmd "mkdir -p $assets_dst"
        run_cmd "cp -R $assets_src/. $assets_dst/"
    else
        log_warn "hello_world flutter_assets not found: $assets_src"
    fi

    local libs_src="$hello_world_dir/ohos/entry/build/default/intermediates/libs/default/arm64-v8a"
    if [[ -d "$libs_src" ]]; then
        local libs_dst="$resource_dir/libs"
        log_info "Collecting hello_world native libs into $libs_dst"
        run_cmd "mkdir -p $libs_dst"
        run_cmd "cp $libs_src/*.so $libs_dst/"
    else
        log_warn "hello_world native libs not found: $libs_src"
    fi
}

prepare_tests "$@"
