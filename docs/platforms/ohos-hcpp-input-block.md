# OHOS HCPP input block

This is a small, reversible input path for HCPP `DISPLAY` platform views. It
does not change the native surface, libmpv, HDR output, main Flutter
`XComponent`, Dart player code, or the gesture arena.

## Contract

`PlatformViewsControllerHybrid.onDisplayPlatformViewHybrid` upserts one
observed `HcppInputRect` per visible Dart PlatformView id. The rect uses the
existing `x/y/width/height` physical-pixel-to-vp conversion and is published
in the `hcpp_input_rects_map` AppStorage slice at `onEndFrameHybrid`.

The `FlutterPage` stack order is:

```text
HCPP DISPLAY wrapper < overlay XComponent < transparent input rect < overlay rect block
```

The input rect has `HitTestMode.Block` and forwards ArkUI touch and axis events
to `FlutterView.dispatchTouchToEngineHybrid`/
`dispatchAxisToEngineHybrid`. `DynamicView` does not install a touch or axis
dispatcher for HCPP, so the input block is the only DISPLAY touch entry. The
overlay XComponent is `HitTestMode.None`; it is a composition surface, not a
second input entry. A `FlutterOverlayBlock` above the input rect owns any
overlapping SliceViews control region; the two routes share the Controller's
pointer owner map and therefore do not inject a second stream. The input rect
never calls `showControls`.

Rect node identity is `hcpp-input-<platformViewId>` and overlay node identity
is `hcpp-overlay-<platformViewId>`; neither key contains coordinates. Both
observed objects are retained while geometry changes, so an animation updates
position/size without rebuilding the ArkUI node. The Controller records the
first Down's `pointerId -> platformViewId` owner. `visible=false` rejects only
a new Down; Move/Up/Cancel for an owned pointer remain eligible. Before a
hide, dispose, detach, restart, zero rect, or absent end-frame target, the
Controller sends a CANCEL through the same `dispatchTouchToEngine` route, then
removes that view's input and overlay storage entries before deleting geometry.
The storage maps remain partitioned by target FlutterView string id.

The existing `nativeDispatchTouchToEngine` embedding ABI currently reads the
touch fields only; it does not read a `view_id` field. Its `PointerData` is
shell-scoped and remains at the implicit view id (`0`) after native
initialization. The embedding therefore selects the target shell through the
FlutterView, and does not incorrectly put the Dart PlatformView id into
PointerData `view_id`.

## Verification

The Hypium test
`PlatformViewsControllerHybrid.test.ets` covers visible publication,
invisible-frame clearing, stable input/overlay identities, display→hide/end,
empty frames, no-Down rejection, terminal delivery after `visible=false`, and
dispose-without-a-next-frame cancellation. The static z-order/single-entry
contract can be run from the repository root with:

```sh
bash engine/src/flutter/shell/platform/ohos/flutter_embedding/flutter/test/hcpp_input_block_contract_test.sh
```

These are embedding contract checks. They do not replace physical-device
acceptance: a signed/installed HAP and a visible native DISPLAY still need
real-device down/move/up/cancel, overlap-control, destroy/recreate, and HDR
regression checks.
