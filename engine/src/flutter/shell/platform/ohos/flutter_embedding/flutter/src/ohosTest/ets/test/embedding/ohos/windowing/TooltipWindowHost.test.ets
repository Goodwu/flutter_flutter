/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { describe, expect, it, Level } from '@ohos/hypium';
import window from '@ohos.window';
import UIAbility from '@ohos.app.ability.UIAbility';
import { TooltipWindowHost } from
  '../../../../../../main/ets/embedding/ohos/windowing/TooltipWindowHost';
import { WindowArchetype } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowArchetype';
import { WindowHostContext } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowHostContext';
import { FlutterView } from '../../../../../../main/ets/view/FlutterView';
import { FakeWindow, FakeWindowStage, FakeAbility, FakeFlutterView, FakeHostContext, sleep } from './Fakes';

/** Concrete subclass exposing TooltipWindowHost's protected hooks. */
class TestTooltipHost extends TooltipWindowHost {
  constructor(ctx: WindowHostContext, viewId: number, parentViewId: number, w: number, h: number) {
    super(ctx, viewId, parentViewId, w, h);
  }

  defaultLogicalSizeForTest(): number[] {
    return this.defaultLogicalSize();
  }

  async prepareShowForTest(subWindow: window.Window): Promise<void> {
    await this.prepareShow(subWindow);
  }

  startParentTrackingForTest(): void {
    this.startParentTracking();
  }

  setParentForTest(ability: UIAbility | undefined): void {
    this.parentAbility = ability;
  }
}

/** Tooltip + resolved parent (ability main) window + own sub-window bundle
 * with parent tracking already started. */
class TooltipWithParent {
  ctx: FakeHostContext;
  parentWin: FakeWindow;
  sub: FakeWindow;
  host: TestTooltipHost;

  constructor(viewId: number) {
    const stage = new FakeWindowStage();
    const parentWin = new FakeWindow();
    stage.mainWindow = parentWin as ESObject as window.Window;
    const ctx = new FakeHostContext();
    ctx.stage = stage as ESObject as window.WindowStage;
    const ability: UIAbility = new FakeAbility() as ESObject as UIAbility;
    ctx.parentAbilityFor = ability;
    ctx.flutterViews.set(String(viewId), new FakeFlutterView() as ESObject as FlutterView);
    const host = new TestTooltipHost(ctx, viewId, 9, 100, 80);
    host.subWindow = new FakeWindow() as ESObject as window.Window;
    host.setParentForTest(ability);
    host.startParentTrackingForTest();
    this.ctx = ctx;
    this.parentWin = parentWin;
    this.sub = host.subWindow as ESObject as FakeWindow;
    this.host = host;
  }
}

export default function tooltipWindowHostTest() {
  describe('TooltipWindowHost.constructor', () => {
    it('passes the TOOLTIP archetype', Level.LEVEL0, () => {
      const ctx = new FakeHostContext();
      const host: TestTooltipHost = new TestTooltipHost(ctx, 1, 0, 100, 80);
      expect(host.archetype).assertEqual(WindowArchetype.TOOLTIP);
    });
  });

  describe('TooltipWindowHost.defaultLogicalSize', () => {
    it('defaults to 400x200', Level.LEVEL0, () => {
      const ctx = new FakeHostContext();
      const host: TestTooltipHost = new TestTooltipHost(ctx, 2, 0, 100, 80);
      const def = host.defaultLogicalSizeForTest();
      expect(def.length).assertEqual(2);
      expect(def[0]).assertEqual(400);
      expect(def[1]).assertEqual(200);
    });
  });

  describe('TooltipWindowHost.prepareShow', () => {
    it('disables focusability', Level.LEVEL0, async (done: Function) => {
      const ctx = new FakeHostContext();
      const fake = new FakeWindow();
      const host: TestTooltipHost = new TestTooltipHost(ctx, 3, 0, 100, 80);
      await host.prepareShowForTest(fake as ESObject as window.Window);
      expect(fake.focusable).assertFalse();
      done();
    });

    it('logs a rejected focusable set', Level.LEVEL0, async (done: Function) => {
      const ctx = new FakeHostContext();
      const fake = new FakeWindow();
      fake.rejectFocusable = true;
      const host: TestTooltipHost = new TestTooltipHost(ctx, 4, 0, 100, 80);
      await host.prepareShowForTest(fake as ESObject as window.Window);
      expect(fake.focusable).assertTrue();
      done();
    });
  });

  describe('TooltipWindowHost.onParentWindowEvent', () => {
    it('destroys IMMEDIATELY on parent WINDOW_INACTIVE (win32 WA_INACTIVE)',
      Level.LEVEL0, async (done: Function) => {
        const p = new TooltipWithParent(10);
        expect(p.parentWin.windowEventCb).not().assertUndefined();
        p.parentWin.windowEventCb?.(window.WindowEventType.WINDOW_INACTIVE);
        // Synchronous, zero grace — win32 tooltip destroys unconditionally
        // on the parent's WA_INACTIVE; the tooltip is non-focusable, so
        // that INACTIVE can never be self-caused.
        expect(p.sub.destroyCount).assertEqual(1); // OS sub-window removed
        expect(p.ctx.removedHosts.includes('10')).assertTrue(); // host dropped
        // Teardown never re-shows the parent (win32 DestroyWindow parity):
        // a stray showWindow would steal focus from its new holder.
        expect(p.ctx.restoredForegrounds.includes('10')).assertFalse();
        // Teardown released BOTH parent listeners (rect + lifecycle).
        expect(p.parentWin.windowEventCb).assertUndefined();
        expect(p.parentWin.rectChangeCb).assertUndefined();
        expect(p.host.anchored).assertFalse();
        done();
      });

    it('parent WINDOW_ACTIVE destroys nothing', Level.LEVEL0,
      async (done: Function) => {
        const p = new TooltipWithParent(11);
        p.parentWin.windowEventCb?.(window.WindowEventType.WINDOW_ACTIVE);
        await sleep(80); // prove no deferred close either
        expect(p.sub.destroyCount).assertEqual(0);
        expect(p.host.anchored).assertTrue();
        done();
      });

    it('ignores other parent lifecycle events', Level.LEVEL0, async (done: Function) => {
      const p = new TooltipWithParent(12);
      p.parentWin.windowEventCb?.(window.WindowEventType.WINDOW_SHOWN);
      expect(p.sub.destroyCount).assertEqual(0);
      await sleep(80); // prove no deferred close either
      expect(p.sub.destroyCount).assertEqual(0);
      expect(p.host.anchored).assertTrue();
      done();
    });

    it('destroys on parent WINDOW_DESTROYED (orphan guard)', Level.LEVEL0,
      async (done: Function) => {
        const p = new TooltipWithParent(13);
        // The destroy event is the parent's LAST — without this branch a
        // destroyed parent (never INACTIVE, no further rect events) leaves
        // the non-focusable tooltip orphaned on screen forever.
        p.parentWin.windowEventCb?.(window.WindowEventType.WINDOW_DESTROYED);
        expect(p.sub.destroyCount).assertEqual(1); // OS sub-window removed
        expect(p.ctx.removedHosts.includes('13')).assertTrue(); // host dropped
        expect(p.parentWin.windowEventCb).assertUndefined(); // listeners off'd
        expect(p.parentWin.rectChangeCb).assertUndefined();
        expect(p.host.anchored).assertFalse();
        done();
      });
  });
}
