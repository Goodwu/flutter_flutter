#!/bin/bash
# Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE_HW file.

# 'Collect Dashboard Data' test-step entry: aggregate the execution logs
# of one SDK unit-test round into a single framework-data record, then
# merge every pending per-round copy into the OBS daily file
# (cloud_test:// protocol, via the cipd `archive` CLI).
# Non-fatal: any failure only prints a warning.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 "$SCRIPT_DIR/collect_sdk_unit_dashboard.py" --archive \
    || echo "[$(date +%H:%M:%S)] WARN: SDK dashboard collection failed (non-fatal)"
exit 0
