#!/bin/bash
# Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE_HW file.
#
# OHOS CI Runner
#
# Unified entry point for CI stages. Delegates to runner.py with the
# appropriate stage name based on the sub-command provided.
#
# Usage: sh ./third_party/flutter_flutter/ci/ohos_ci_runner.sh <stage>
#   stage: prepare    -> preparation
#          compile    -> compilation
#          test       -> test
#          integration-> integration
#          customer   -> customer

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/scripts/runner.py"

STAGE="$1"

if [[ -z "$STAGE" ]]; then
    echo "[ERROR] Stage not provided"
    echo "Usage: $0 <prepare|compile|test|integration|customer>"
    exit 1
fi

case "$STAGE" in
    prepare|preparation)
        STAGE="preparation"
        ;;
    compile|compilation)
        STAGE="compilation"
        ;;
    test)
        STAGE="test"
        ;;
    integration)
        STAGE="integration"
        ;;
    customer)
        STAGE="customer"
        ;;
    *)
        echo "[ERROR] Unknown stage: $STAGE"
        echo "Usage: $0 <prepare|compile|test|integration|customer>"
        exit 1
        ;;
esac

if ! command -v python3 &> /dev/null; then
    echo "[ERROR] Python 3 is required but not installed."
    exit 1
fi

python3 -c "import yaml" 2>/dev/null || {
    echo "[ERROR] PyYAML is not installed. Run: pip install pyyaml"
    exit 1
}

python3 "$RUNNER" "$STAGE"
