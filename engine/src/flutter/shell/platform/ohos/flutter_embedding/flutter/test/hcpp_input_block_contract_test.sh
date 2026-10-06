#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../../../../../../../.." && pwd)"
page="$repo_root/engine/src/flutter/shell/platform/ohos/flutter_embedding/flutter/src/main/ets/embedding/ohos/FlutterPage.ets"
controller="$repo_root/engine/src/flutter/shell/platform/ohos/flutter_embedding/flutter/src/main/ets/plugin/platform/PlatformViewsControllerHybrid.ets"

rg -q 'hcpp_input_rects_map' "$controller"
rg -q 'onDisplayPlatformViewHybrid' "$controller"
rg -q 'displayedHcppInputViewIds' "$controller"
rg -q 'hcppInputRectKey\(platformViewId: number, attachmentEpoch: number = 0\)' "$controller"
rg -q 'hcppOverlayRectKey\(platformViewId: number, attachmentEpoch: number = 0\)' "$controller"
rg -q 'hcppInputRectKey\(rect\.platformViewId, rect\.attachmentEpoch\)' "$page"
rg -q 'hcppOverlayRectKey\(rect\.viewId, rect\.attachmentEpoch\)' "$page"
rg -q 'dispatchTouchToEngineHybrid\(' "$page"
rg -q 'rect\.attachmentEpoch' "$page"
rg -q '\.hitTestBehavior\(HitTestMode\.Block\)' "$page"
! rg -q 'touchDispatcher|axisDispatcher' \
  "$repo_root/engine/src/flutter/shell/platform/ohos/flutter_embedding/flutter/src/main/ets/view/DynamicView/dynamicView.ets" \
  "$controller"

input_block="$(sed -n '/struct HcppInputRectBlock/,/^\/\*\* The HCPP input rect collection/p' "$page")"
! grep -q 'if (!this.rect.visible)' <<<"$input_block"
! grep -q 'showControls' <<<"$input_block"
grep -q 'dispatchTouchToEngineHybrid' <<<"$input_block"
grep -q 'dispatchAxisToEngineHybrid' <<<"$input_block"
grep -q 'this.rect.attachmentEpoch' <<<"$input_block"

# A terminal event is decided by ControllerHybrid's owner map, not by the
# input block's current visibility flag.
rg -q 'activeTouchPointers' "$controller"
rg -q 'traceSeq: number' "$controller"
rg -q 'ownerSeq: number' "$controller"
rg -q 'ownerSeq=' "$controller"
rg -q 'stale-attachment' "$controller"
rg -q 'pendingOverlayRects = \[\]' "$controller"
rg -q 'this\.hcppInputAttachmentEpochs\.set\(viewId, disposeEpoch \+ 1\)' "$controller"
rg -q "reason='dispose'|reason=\"dispose\"|'dispose'" "$controller"
rg -q 'removeHcppInputRectFromStorage' "$controller"

# The overlay block is rendered after the input layer in both HCPP page
# builders. It therefore owns overlap regions and prevents duplicate injects.
default_page="$(awk '/^  defaultPage\(\)/ {capture=1} /^  mouseWheelPage\(\)/ {exit} capture {print}' "$page")"
mouse_page="$(awk '/^  mouseWheelPage\(\)/ {capture=1} /^  build\(\)/ && capture {exit} capture {print}' "$page")"
test "$(grep -c 'this.buildHcppInputBlock()' <<<"$default_page")" -eq 1
test "$(grep -c 'this.buildOverlayBlock()' <<<"$default_page")" -eq 1
test "$(grep -n 'this.buildHcppInputBlock()' <<<"$default_page" | cut -d: -f1)" -lt \
  "$(grep -n 'this.buildOverlayBlock()' <<<"$default_page" | cut -d: -f1)"
test "$(grep -c 'this.buildHcppInputBlock()' <<<"$mouse_page")" -eq 1
test "$(grep -c 'this.buildOverlayBlock()' <<<"$mouse_page")" -eq 1
test "$(grep -n 'this.buildHcppInputBlock()' <<<"$mouse_page" | cut -d: -f1)" -lt \
  "$(grep -n 'this.buildOverlayBlock()' <<<"$mouse_page" | cut -d: -f1)"

echo "HCPP input block contract: PASS"
