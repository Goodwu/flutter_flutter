/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { describe, expect, it, Level } from '@ohos/hypium';
import window from '@ohos.window';
import { TooltipWindowHost, BirthPlacement } from
  '../../../../../../main/ets/embedding/ohos/windowing/TooltipWindowHost';
import { WindowPositionResult } from
  '../../../../../../main/ets/embedding/engine/FlutterNapi';
import { WindowArchetype } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowingUtils';
import { WindowHostContext } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowHostContext';
import { FakeWindow, FakeHostContext, FakeRect, sleep, tooltipRequest } from './Fakes';

/** Concrete subclass exposing the protected hooks. */
class TestTooltipHost extends TooltipWindowHost {
  constructor(ctx: WindowHostContext, viewId: number, parentViewId: number) {
    super(ctx, viewId, tooltipRequest(parentViewId));
  }

  // ---- computePlacementRect seams ----

  /** Fixed density for the positioner math AND the base size funnel
   * (densityPixels now lives on FlutterWindowHost, so the override feeds
   * both — deterministic regardless of the test device). */
  testDpr: number = 2.0;

  /** Fake positioner outcome: 0 → returns placeLogical, else "no
   * positioner" (the native rc !== 0 default-placement branch). */
  placementRc: number = 1;
  placeLogical: window.Rect = { left: 160, top: 240, width: 250, height: 100 };

  /** Positioner invocation args in call order (child W/H, parent L/T/W/H,
   * work L/T/W/H — all LOGICAL). */
  placementArgs: Array<number> = new Array<number>();

  /** Positioner invocation count (dedup/coalescing probes). */
  placementCalls: number = 0;

  /** Work area handed to the positioner (PHYSICAL; default = full
   * 1000x800 display like the phone fallback). */
  workAreaPhysicalRect: window.Rect = { left: 0, top: 0, width: 1000, height: 800 };

  protected computePlacement(pos: WindowPositionResult,
                             childSize: window.Size,
                             parentRect: window.Rect,
                             workArea: window.Rect): boolean {
    this.placementArgs = [childSize.width, childSize.height,
      parentRect.left, parentRect.top, parentRect.width, parentRect.height,
      workArea.left, workArea.top, workArea.width, workArea.height];
    this.placementCalls += 1;
    if (this.placementRc === 0) {
      pos.set(this.placeLogical.left, this.placeLogical.top,
        this.placeLogical.width, this.placeLogical.height);
      return true;
    }
    return false;
  }

  protected async workAreaPhysical(): Promise<window.Rect> {
    return this.workAreaPhysicalRect;
  }

  protected densityPixels(_parentWnd: window.Window | undefined): number {
    return this.testDpr;
  }

  async placementRectForTest(parentWnd: window.Window,
                             logical: window.Size): Promise<BirthPlacement> {
    return this.computePlacementRect(parentWnd, logical);
  }
}

// Parent-move tracking / policy close is deliberately NOT host-side (the
// old attempts were compensation artifacts); the window's lifetime policy
// belongs to the framework, not to this host.

/** Parent with a decorated frame: outer (100,200 1000x800), the (10,20)
 * decoration inset — drawableRect is FRAME-LOCAL physical px (device-
 * verified), so the content rect sits at screen (110,220 980x760) after
 * the ClientToScreen translate by the frame origin. */
function decoratedParent(): FakeWindow {
  const fake = new FakeWindow();
  fake.props.windowRect = new FakeRect(100, 200, 1000, 800) as ESObject as window.Rect;
  fake.props.drawableRect = new FakeRect(10, 20, 980, 760) as ESObject as window.Rect;
  return fake;
}

/** A tooltip host with `own` mounted as its OS window and a view-0
 * parent host holding `parent` (both registered in the context). */
function mountedHost(ctx: FakeHostContext, own: FakeWindow,
                     parent: FakeWindow, viewId: number): TestTooltipHost {
  const parentHost = new TestTooltipHost(ctx, 0, 0);
  parentHost.setWindow(parent as ESObject as window.Window);
  ctx.hosts.set('0', parentHost);
  const host = new TestTooltipHost(ctx, viewId, 0);
  host.setWindow(own as ESObject as window.Window);
  return host;
}

export default function tooltipWindowHostTest() {
  describe('TooltipWindowHost.constructor', () => {
    it('passes the TOOLTIP archetype', Level.LEVEL0, () => {
      const ctx = new FakeHostContext();
      const host: TestTooltipHost = new TestTooltipHost(ctx, 1, 0);
      expect(host.archetype).assertEqual(WindowArchetype.TOOLTIP);
    });
  });

  // prepareShow is gone from the host (never-focusable is now birth-only:
  // showWindow({ focusOnShow: false }) inside attach) — no unit seam remains.

  describe('TooltipWindowHost.computePlacementRect', () => {
    it('anchors at the positioner result, logical→physical ×dpr',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const parent = decoratedParent();
        const host = new TestTooltipHost(ctx, 5, 0);
        host.placementRc = 0; // positioner present → (160,240 250x100) logical
        const birth = await host.placementRectForTest(
          parent as ESObject as window.Window, { width: 400, height: 200 });
        expect(birth.placed).assertTrue();
        expect(birth.rect.left).assertEqual(320);  // 160 × 2.0
        expect(birth.rect.top).assertEqual(480);   // 240 × 2.0
        expect(birth.rect.width).assertEqual(500); // 250 × 2.0
        expect(birth.rect.height).assertEqual(200);// 100 × 2.0
        done();
      });

    it('feeds the positioner preferred-logical size + parent content rect + work area, all logical',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const parent = decoratedParent();
        const host = new TestTooltipHost(ctx, 6, 0);
        host.placementRc = 0;
        await host.placementRectForTest(
          parent as ESObject as window.Window, { width: 400, height: 200 });
        const a = host.placementArgs;
        expect(a.length).assertEqual(10);
        // Child = preferred LOGICAL size (win32 passes width_/height_).
        expect(a[0]).assertEqual(400);
        expect(a[1]).assertEqual(200);
        // Parent content origin = drawableRect (screen px) / dpr.
        expect(a[2]).assertEqual(55);   // 110 / 2
        expect(a[3]).assertEqual(110);  // 220 / 2
        expect(a[4]).assertEqual(490);  // 980 / 2
        expect(a[5]).assertEqual(380);  // 760 / 2
        // Work area physical 1000x800 → logical.
        expect(a[6]).assertEqual(0);
        expect(a[7]).assertEqual(0);
        expect(a[8]).assertEqual(500);
        expect(a[9]).assertEqual(400);
        done();
      });

    it('keeps default system placement when there is no positioner (rc !== 0)',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const parent = decoratedParent();
        const host = new TestTooltipHost(ctx, 7, 0);
        host.placementRc = 1;
        const birth = await host.placementRectForTest(
          parent as ESObject as window.Window, { width: 400, height: 200 });
        expect(birth.placed).assertFalse();
        // {0,0} sentinel + funnel size (logical 400x200 × override dpr 2.0).
        expect(birth.rect.left).assertEqual(0);
        expect(birth.rect.top).assertEqual(0);
        expect(birth.rect.width).assertEqual(800);
        expect(birth.rect.height).assertEqual(400);
        // The positioner was still consulted with the preferred size.
        expect(host.placementArgs[0]).assertEqual(400);
        expect(host.placementArgs[1]).assertEqual(200);
        done();
      });

    it('applies a positioner shrink to the birth size (win32 rect verbatim)',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const parent = decoratedParent();
        const host = new TestTooltipHost(ctx, 8, 0);
        host.placementRc = 0;
        host.placeLogical = { left: 160, top: 240, width: 120, height: 80 };
        const birth = await host.placementRectForTest(
          parent as ESObject as window.Window, { width: 400, height: 200 });
        expect(birth.placed).assertTrue();
        expect(birth.rect.width).assertEqual(240);  // 120 × 2.0
        expect(birth.rect.height).assertEqual(160); // 80 × 2.0
        done();
      });

    it('keeps the funnel size when the positioner returns degenerate dims',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const parent = decoratedParent();
        const host = new TestTooltipHost(ctx, 9, 0);
        host.placementRc = 0;
        host.placeLogical = { left: 160, top: 240, width: 0, height: 0 };
        const birth = await host.placementRectForTest(
          parent as ESObject as window.Window, { width: 400, height: 200 });
        expect(birth.placed).assertTrue();
        expect(birth.rect.left).assertEqual(320);
        expect(birth.rect.top).assertEqual(480);
        // Funnel fallback (× dpr) applied verbatim — no host-side work-area
        // clamp (win32 parity; only the positioner's resize adjustments
        // may shrink the rect).
        expect(birth.rect.width).assertEqual(800);
        expect(birth.rect.height).assertEqual(400);
        done();
      });
  });

  describe('TooltipWindowHost.didUpdateViewSize', () => {
    it('feeds the stored content size (physical→logical ÷dpr) to the positioner, not the birth size',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const own = new FakeWindow();
        const parent = new FakeWindow();
        const host = mountedHost(ctx, own, parent, 11);
        host.placementRc = 0;

        // Before any frame: updatePosition sees the BIRTH size (default
        // 400x200 — the request carries no constraints).
        await host.updatePosition();
        expect(host.placementCalls).assertEqual(1);
        expect(host.placementArgs[0]).assertEqual(400);
        expect(host.placementArgs[1]).assertEqual(200);

        // Content size arrives (PHYSICAL px); dpr = 2 → logical 300x150.
        host.didUpdateViewSize(600, 300);
        await sleep(0);
        expect(host.placementCalls).assertEqual(2);
        expect(host.placementArgs[0]).assertEqual(300);
        expect(host.placementArgs[1]).assertEqual(150);
        done();
      });

    it('dedups unchanged content sizes (win32 DidUpdateViewSize early-out)',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const own = new FakeWindow();
        const parent = new FakeWindow();
        const host = mountedHost(ctx, own, parent, 12);
        host.placementRc = 0;

        host.didUpdateViewSize(600, 300);
        host.didUpdateViewSize(600, 300);  // unchanged → no re-placement
        await sleep(0);
        expect(host.placementCalls).assertEqual(1);
        done();
      });

    it('coalesces reports arriving while a placement is in flight (latest wins)',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const own = new FakeWindow();
        const parent = new FakeWindow();
        const host = mountedHost(ctx, own, parent, 13);
        host.placementRc = 0;

        // Three reports back-to-back while the first placement is still
        // awaiting its microtasks: exactly two runs (first + one pending
        // re-run), the re-run seeing the LATEST content size (400x200).
        host.didUpdateViewSize(600, 300);
        host.didUpdateViewSize(700, 350);
        host.didUpdateViewSize(800, 400);
        await sleep(0);
        await sleep(0);
        expect(host.placementCalls).assertEqual(2);
        expect(host.placementArgs[0]).assertEqual(400);
        expect(host.placementArgs[1]).assertEqual(200);
        done();
      });

    it('moves and resizes the sub-window to the positioner rect (physical)',
      Level.LEVEL0, async (done: Function) => {
        const ctx = new FakeHostContext();
        const own = new FakeWindow();
        const parent = new FakeWindow();
        const host = mountedHost(ctx, own, parent, 14);
        host.placementRc = 0;
        // Logical (160,240 250x100) × dpr 2 → physical (320,480 500x200).
        host.didUpdateViewSize(600, 300);
        await sleep(0);
        await sleep(0);
        expect(own.moveCalls.length).assertEqual(1);
        expect(own.moveCalls[0][0]).assertEqual(320);
        expect(own.moveCalls[0][1]).assertEqual(480);
        // FakeWindow starts at 1000x800 → the 500x200 rect is applied.
        expect(own.resizeCalls.length).assertEqual(1);
        expect(own.resizeCalls[0][0]).assertEqual(500);
        expect(own.resizeCalls[0][1]).assertEqual(200);
        done();
      });
  });
}
