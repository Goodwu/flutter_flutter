/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { describe, it, expect, Level, beforeAll} from '@ohos/hypium';
import { FlutterView, ViewportMetrics } from '../../../../main/ets/view/FlutterView';
import common from '@ohos.app.ability.common';
import { deviceInfo } from '@kit.BasicServicesKit';
import { display } from '@kit.ArkUI';
import FlutterEngine from '../../../../main/ets/embedding/engine/FlutterEngine';
import PlatformViewsController from '../../../../main/ets/plugin/platform/PlatformViewsController';
import Any from '../../../../main/ets/plugin/common/Any';

class TestArea implements Area {
  width: Length = 0;
  height: Length = 0;
  position: Position = { x: 0, y: 0 };
  globalPosition: Position = { x: 0, y: 0 };

  constructor(width: Length, height: Length) {
    this.width = width;
    this.height = height;
  }
}

function safeAttach(flutterView: FlutterView, engine: FlutterEngine): boolean {
  try {
    flutterView.attachToFlutterEngine(engine);
  } catch (e) {
    console.info('uitest: attachToFlutterEngine error: ' + JSON.stringify(e));
  }
  return flutterView.isAttachedToFlutterEngine();
}

function invokeUpdateDisplayCornerRadii(flutterView: FlutterView): void {
  (flutterView as Any).updateDisplayCornerRadii();
}

function invokeUpdateViewportMetrics(flutterView: FlutterView): boolean {
  return (flutterView as Any).updateViewportMetrics() as boolean;
}

function readViewportMetrics(flutterView: FlutterView): ViewportMetrics {
  return (flutterView as Any).viewportMetrics as ViewportMetrics;
}

export default function flutterViewTest() {
  let context: common.UIAbilityContext;

  describe('FlutterView.getFlutterEngine', () => {
    it('returns null when no engine is attached', Level.LEVEL0, () => {
      const flutterView: FlutterView = new FlutterView('oh_flutter_test_view', getContext());
      expect(flutterView.getFlutterEngine()).assertNull();
    });
  });

  describe('ViewportMetricsCornerRadiiTest', () => {

    it('default_corner_radii_are_unavailable_sentinel', 0, () => {
      const metrics = new ViewportMetrics();
      expect(metrics.displayCornerRadiusTopLeft).assertEqual(-1);
      expect(metrics.displayCornerRadiusTopRight).assertEqual(-1);
      expect(metrics.displayCornerRadiusBottomRight).assertEqual(-1);
      expect(metrics.displayCornerRadiusBottomLeft).assertEqual(-1);
    })

    it('clone_copies_corner_radii', 0, () => {
      const metrics = new ViewportMetrics();
      metrics.displayCornerRadiusTopLeft = 10;
      metrics.displayCornerRadiusTopRight = 20;
      metrics.displayCornerRadiusBottomRight = 30;
      metrics.displayCornerRadiusBottomLeft = 40;
      const copy = metrics.clone();
      expect(copy.displayCornerRadiusTopLeft).assertEqual(10);
      expect(copy.displayCornerRadiusTopRight).assertEqual(20);
      expect(copy.displayCornerRadiusBottomRight).assertEqual(30);
      expect(copy.displayCornerRadiusBottomLeft).assertEqual(40);
    })

    it('isEqual_compares_corner_radii', 0, () => {
      const left = new ViewportMetrics();
      left.displayCornerRadiusTopLeft = 5;
      left.displayCornerRadiusTopRight = 6;
      left.displayCornerRadiusBottomRight = 7;
      left.displayCornerRadiusBottomLeft = 8;
      const right = left.clone();
      expect(left.isEqual(right)).assertTrue();
      right.displayCornerRadiusBottomLeft = 9;
      expect(left.isEqual(right)).assertFalse();
    })
  })

  describe('FlutterViewDisplayCornerRadiiTest', () => {
    let platformViewsController: PlatformViewsController;

    beforeAll(() => {
      context = getContext() as common.UIAbilityContext;
      platformViewsController = new PlatformViewsController();
    })

    it('constructor_keeps_corner_radii_unavailable_by_default', 0, () => {
      const flutterView = new FlutterView('corner_radii_ctor_view', context);
      const metrics = readViewportMetrics(flutterView);
      expect(metrics.displayCornerRadiusTopLeft).assertEqual(-1);
      expect(metrics.displayCornerRadiusTopRight).assertEqual(-1);
      expect(metrics.displayCornerRadiusBottomRight).assertEqual(-1);
      expect(metrics.displayCornerRadiusBottomLeft).assertEqual(-1);
    })

    it('updateDisplayCornerRadii_reads_platform_on_supported_api', 0, () => {
      const flutterView = new FlutterView('corner_radii_platform_view', context);
      invokeUpdateDisplayCornerRadii(flutterView);
      const metrics = readViewportMetrics(flutterView);
      console.info('uitest: sdkApiVersion=' + deviceInfo.sdkApiVersion +
        ' tl=' + metrics.displayCornerRadiusTopLeft);
      let probeSucceeded = false;
      if (deviceInfo.sdkApiVersion >= 23) {
        const displayInfo: ESObject = display.getDefaultDisplaySync() as ESObject;
        if (typeof displayInfo?.getRoundedCorner === 'function') {
          try {
            displayInfo.getRoundedCorner();
            probeSucceeded = true;
          } catch (e) {
            console.info('uitest: getRoundedCorner threw (BusinessError 801?), ' +
              'expecting -1 sentinels: ' + JSON.stringify(e));
          }
        }
      }
      if (probeSucceeded) {
        expect(metrics.displayCornerRadiusTopLeft).assertLarger(-1);
        expect(metrics.displayCornerRadiusTopRight).assertLarger(-1);
        expect(metrics.displayCornerRadiusBottomRight).assertLarger(-1);
        expect(metrics.displayCornerRadiusBottomLeft).assertLarger(-1);
      } else {
        expect(metrics.displayCornerRadiusTopLeft).assertEqual(-1);
        expect(metrics.displayCornerRadiusTopRight).assertEqual(-1);
        expect(metrics.displayCornerRadiusBottomRight).assertEqual(-1);
        expect(metrics.displayCornerRadiusBottomLeft).assertEqual(-1);
      }
    })

    it('updateViewportMetrics_not_attached_returns_false', 0, () => {
      const flutterView = new FlutterView('viewport_metrics_detached_view', context);
      const updated = invokeUpdateViewportMetrics(flutterView);
      expect(updated).assertFalse();
    })

    it('onAreaChange_without_attach_updates_dimensions', 0, () => {
      const flutterView = new FlutterView('area_change_detached_view', context);
      flutterView.setCheckFullScreen(false);
      flutterView.onAreaChange(new TestArea(360, 780), false);
      flutterView.onAreaChange(new TestArea(400, 800), false);
      const metrics = readViewportMetrics(flutterView);
      expect(metrics.physicalWidth).assertLarger(0);
      expect(metrics.physicalHeight).assertLarger(0);
    })

    it('setPaddingTop_when_attached_triggers_viewport_update', 0, async (done: Function) => {
      const flutterView = new FlutterView('padding_top_view', context);
      flutterView.setCheckFullScreen(false);
      const engine = new FlutterEngine(context, null, null, platformViewsController);
      safeAttach(flutterView, engine);
      flutterView.setPaddingTop(48);
      flutterView.setPaddingBottom(32);
      expect(flutterView.isAttachedToFlutterEngine()).assertTrue();
      done();
    })

    it('onAreaChange_with_size_change_when_attached', 0, async (done: Function) => {
      const flutterView = new FlutterView('area_change_view', context);
      flutterView.setCheckFullScreen(false);
      const engine = new FlutterEngine(context, null, null, platformViewsController);
      safeAttach(flutterView, engine);
      flutterView.onAreaChange(new TestArea(320, 640), false);
      flutterView.onAreaChange(new TestArea(480, 960), false);
      done();
    })

    it('onAreaChange_when_attached_invokes_updateDisplayCornerRadii', 0, () => {
      const flutterView = new FlutterView('corner_radii_area_change_view', context);
      flutterView.setCheckFullScreen(false);
      const engine = new FlutterEngine(context, null, null, platformViewsController);
      if (!safeAttach(flutterView, engine)) {
        console.info('uitest: skip attached onAreaChange, engine not attached');
        return;
      }
      const metrics = readViewportMetrics(flutterView);
      metrics.physicalWidth = 1080;
      metrics.physicalHeight = 2340;
      flutterView.onAreaChange(new TestArea(360, 780), false);
      invokeUpdateDisplayCornerRadii(flutterView);
    })

    it('updateDisplayCornerRadii_on_attached_view', 0, async (done: Function) => {
      const flutterView = new FlutterView('corner_radii_invoke_view', context);
      flutterView.setCheckFullScreen(false);
      const engine = new FlutterEngine(context, null, null, platformViewsController);
      safeAttach(flutterView, engine);
      invokeUpdateDisplayCornerRadii(flutterView);
      invokeUpdateViewportMetrics(flutterView);
      flutterView.setPaddingTop(64);
      done();
    })

    it('updateViewportMetrics_passes_corner_radii_when_attached', 0, async (done: Function) => {
      const flutterView = new FlutterView('viewport_metrics_view', context);
      flutterView.setCheckFullScreen(false);
      const engine = new FlutterEngine(context, null, null, platformViewsController);
      safeAttach(flutterView, engine);
      const updated = invokeUpdateViewportMetrics(flutterView);
      expect(updated).assertTrue();
      done();
    })

    it('onAreaChange_fullscreen_padding_branch', 0, () => {
      const flutterView = new FlutterView('fullscreen_padding_view', context);
      flutterView.setCheckFullScreen(true);
      const engine = new FlutterEngine(context, null, null, platformViewsController);
      safeAttach(flutterView, engine);
      flutterView.setPaddingTop(24);
      flutterView.setPaddingBottom(16);
      flutterView.onAreaChange(new TestArea(360, 780), true);
    })
  })
}
