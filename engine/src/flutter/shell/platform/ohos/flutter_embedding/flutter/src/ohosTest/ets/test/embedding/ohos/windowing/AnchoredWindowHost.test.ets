/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { describe, expect, it, Level } from '@ohos/hypium';
import window from '@ohos.window';
import display from '@ohos.display';
import UIAbility from '@ohos.app.ability.UIAbility';
import { AnchoredWindowHost, WorkArea } from
  '../../../../../../main/ets/embedding/ohos/windowing/AnchoredWindowHost';
import { WindowPositionResult } from
  '../../../../../../main/ets/embedding/engine/FlutterNapi';
import { WindowArchetype } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowArchetype';
import { WindowHostContext } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowHostContext';
import {
  FakeWindow, FakeWindowNoShadow, FakeWindowStage, FakeWindowProperties,
  FakeAbility, FakeHostContext, FakeRect, sleep,
} from './Fakes';

/** Concrete subclass exposing the protected hooks of AnchoredWindowHost. */
class TestAnchoredHost extends AnchoredWindowHost {
  /** When set, computePlacement fills pos from [left, top, w, h] (LOGICAL)
   * and reports success; otherwise the real native round trip runs. */
  simulatePlacement: number[] | undefined = undefined;
  /** When set, workAreaPhysical fills from [left, top, w, h] (PHYSICAL)
   * instead of querying the real display. */
  workOverride: number[] | undefined = undefined;
  /** computePlacement args of the last call:
   * [lw, lh, pL, pT, pW, pH, wL, wT, wW, wH] (LOGICAL). */
  placementArgs: number[] = new Array<number>();

  constructor(ctx: WindowHostContext, viewId: number, parentViewId: number, w: number, h: number) {
    super(ctx, viewId, parentViewId, WindowArchetype.TOOLTIP, w, h);
  }

  protected computePlacement(pos: WindowPositionResult,
                             logicalW: number, logicalH: number,
                             parentLeft: number, parentTop: number,
                             parentW: number, parentH: number,
                             workLeft: number, workTop: number,
                             workW: number, workH: number): boolean {
    this.placementArgs = [logicalW, logicalH, parentLeft, parentTop,
                          parentW, parentH, workLeft, workTop, workW, workH];
    if (this.simulatePlacement !== undefined) {
      pos.set(this.simulatePlacement[0], this.simulatePlacement[1],
              this.simulatePlacement[2], this.simulatePlacement[3]);
      return true;
    }
    return super.computePlacement(pos, logicalW, logicalH, parentLeft, parentTop,
                                  parentW, parentH, workLeft, workTop, workW, workH);
  }

  protected async workAreaPhysical(out: WorkArea, disp: display.Display): Promise<void> {
    if (this.workOverride !== undefined) {
      out.left = this.workOverride[0];
      out.top = this.workOverride[1];
      out.width = this.workOverride[2];
      out.height = this.workOverride[3];
      return;
    }
    await super.workAreaPhysical(out, disp);
  }

  setParentForTest(ability: UIAbility | undefined): void {
    this.parentAbility = ability;
  }

  async styleAfterResizeForTest(subWindow: window.Window): Promise<void> {
    await this.styleAfterResize(subWindow);
  }

  async placeInitialForTest(subWindow: window.Window, lw: number, lh: number,
    pw: number, ph: number): Promise<void> {
    await this.placeInitial(subWindow, lw, lh, pw, ph);
  }

  async positionAtForTest(lw: number, lh: number): Promise<void> {
    await this.positionAt(lw, lh);
  }

  startParentTrackingForTest(): void {
    this.startParentTracking();
  }

  async prepareShowForTest(subWindow: window.Window): Promise<void> {
    await this.prepareShow(subWindow);
  }
}

/** getWindowProperties() throws — exercises positionAt's size-seeding
 * fallback (live size unreadable → apply the target unconditionally). */
class ThrowingPropsWindow extends FakeWindow {
  getWindowProperties(): window.WindowProperties {
    throw new Error('props-throws');
  }
}

/** getWindowProperties() throws for the first propsFailCount calls, then
 * behaves — models a transient window-state error (BusinessError 1300002)
 * at tracking start that clears by placement time. */
class PropsFailFirstWindow extends FakeWindow {
  propsFailCount: number = 1;

  getWindowProperties(): window.WindowProperties {
    if (this.propsFailCount > 0) {
      this.propsFailCount -= 1;
      throw new Error('props-transient');
    }
    return super.getWindowProperties();
  }
}

/** resize() parks on a manual gate — simulates OHOS's ANIMATED resize
 * outlasting the 50ms throttle window, the exact window where a
 * fire-and-forget reanchor let a trailing-edge reanchor duplicate the
 * in-flight resize (stale appliedPhysW/H guard read). */
class GatedResizeWindow extends FakeWindow {
  gateOpen: boolean = true;
  private waiters: Array<Function> = new Array<Function>();

  resize(w: number, h: number): Promise<void> {
    this.resizeCalls.push([w, h]);
    if (this.rejectResize) {
      return Promise.reject(new Error('resize-rejected'));
    }
    if (this.gateOpen) {
      this.reflectOuterSize(w, h);
      return Promise.resolve();
    }
    return new Promise<void>((resolve: Function) => {
      this.waiters.push(() => {
        // The size lands only when the parked resize settles.
        this.reflectOuterSize(w, h);
        resolve();
      });
    });
  }

  /** Settles every parked resize; later resizes resolve immediately. */
  openGate(): void {
    this.gateOpen = true;
    const parked: Array<Function> = this.waiters;
    this.waiters = new Array<Function>();
    for (let i = 0; i < parked.length; i++) {
      parked[i]();
    }
  }
}

/** window.RectChangeOptions carrier (ArkTS: no object literals). */
class FakeRectChangeOptions {
  rect: window.Rect;

  constructor(left: number, top: number, width: number, height: number) {
    this.rect = new FakeRect(left, top, width, height) as ESObject as window.Rect;
  }
}

/** Fires a tracked parent window's rect-change callback as a pure MOVE:
 * the event rect mirrors the window's CURRENT props size — the host seeds
 * its resize baseline from exactly those props. */
function fireRectChange(win: FakeWindow): void {
  expect(win.rectChangeCb).not().assertUndefined();
  const wr = win.props.windowRect;
  win.rectChangeCb?.(new FakeRectChangeOptions(wr.left + 40, wr.top + 40,
    wr.width, wr.height) as ESObject as window.RectChangeOptions);
}

/** Fires a parent RESIZE: applies the new size to the fake's props (a real
 * window's properties reflect the change too) and notifies. */
function fireParentResize(win: FakeWindow, width: number, height: number): void {
  expect(win.rectChangeCb).not().assertUndefined();
  const wr = win.props.windowRect;
  win.props.setWindowRect(wr.left, wr.top, width, height);
  win.rectChangeCb?.(new FakeRectChangeOptions(wr.left, wr.top,
    width, height) as ESObject as window.RectChangeOptions);
}

/** drawableRect getter throws — exercises the windowRect fallback. */
class DrThrowingProperties {
  windowRect: window.Rect = new FakeRect(0, 0, 1000, 800) as ESObject as window.Rect;

  get drawableRect(): window.Rect {
    throw new Error('dr-throws');
  }
}

/** Host + resolved context/window/stage bundle (ArkTS: no tuple destructure). */
class PositionedHosts {
  ctx: FakeHostContext;
  mainWin: FakeWindow;
  stage: FakeWindowStage;
  host: TestAnchoredHost;

  constructor(ctx: FakeHostContext, mainWin: FakeWindow, stage: FakeWindowStage,
    host: TestAnchoredHost) {
    this.ctx = ctx;
    this.mainWin = mainWin;
    this.stage = stage;
    this.host = host;
  }
}

/** Host with sub-window + parent ability + stage fully resolved. */
function makePositioned(viewId: number, parentViewId: number): PositionedHosts {
  const stage = new FakeWindowStage();
  const mainWin = new FakeWindow();
  stage.mainWindow = mainWin as ESObject as window.Window;
  const ctx = new FakeHostContext();
  ctx.stage = stage as ESObject as window.WindowStage;
  ctx.dpr = 2.0;
  const ability: UIAbility = new FakeAbility() as ESObject as UIAbility;
  ctx.parentAbilityFor = ability;
  const host = new TestAnchoredHost(ctx, viewId, parentViewId, 100, 80);
  host.subWindow = mainWin as ESObject as window.Window;
  host.setParentForTest(ability);
  return new PositionedHosts(ctx, mainWin, stage, host);
}

/** Host placed against a live parent (move baseline seeded from props). */
async function makeAnchored(viewId: number): Promise<PositionedHosts> {
  const p = makePositioned(viewId, 9);
  const sub = new FakeWindow();
  p.host.subWindow = sub as ESObject as window.Window;
  p.host.workOverride = [0, 0, 2400, 1200];
  p.host.simulatePlacement = [100, 100, 500, 400];
  await p.host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
  await sleep(10); // birth placement settles → 1 move
  return p;
}

export default function anchoredWindowHostTest() {
  describe('AnchoredWindowHost.constructor', () => {
    it('starts unanchored with the TOOLTIP archetype', Level.LEVEL0, () => {
      const ctx = new FakeHostContext();
      const host: TestAnchoredHost = new TestAnchoredHost(ctx, 1, 0, 100, 80);
      expect(host.anchored).assertFalse();
      expect(host.archetype).assertEqual(WindowArchetype.TOOLTIP);
      expect(host.viewId).assertEqual(1);
      expect(host.parentViewId).assertEqual(0);
    });

  });

  describe('AnchoredWindowHost.styleAfterResize', () => {
    it('applies transparent background, zero shadow and zero corner radius', Level.LEVEL0,
      async (done: Function) => {
        const ctx = new FakeHostContext();
        const fake = new FakeWindow();
        const host: TestAnchoredHost = new TestAnchoredHost(ctx, 3, 0, 100, 80);
        await host.styleAfterResizeForTest(fake as ESObject as window.Window);
        expect(fake.backgroundColor).assertEqual('#00000000');
        expect(fake.shadowRadius).assertEqual(0);
        expect(fake.cornerRadius).assertEqual(0);
        done();
      });

    it('logs a throwing background set and still styles the rest', Level.LEVEL0,
      async (done: Function) => {
        const ctx = new FakeHostContext();
        const fake = new FakeWindow();
        fake.bgThrows = true;
        const host: TestAnchoredHost = new TestAnchoredHost(ctx, 4, 0, 100, 80);
        await host.styleAfterResizeForTest(fake as ESObject as window.Window);
        expect(fake.shadowRadius).assertEqual(0);
        expect(fake.cornerRadius).assertEqual(0);
        done();
      });

    it('logs a throwing shadow-radius set and continues to corner', Level.LEVEL0,
      async (done: Function) => {
        const ctx = new FakeHostContext();
        const fake = new FakeWindow();
        fake.shadowThrows = true;
        const host: TestAnchoredHost = new TestAnchoredHost(ctx, 5, 0, 100, 80);
        await host.styleAfterResizeForTest(fake as ESObject as window.Window);
        expect(fake.backgroundColor).assertEqual('#00000000');
        expect(fake.cornerRadius).assertEqual(0);
        done();
      });

    it('logs a rejected corner-radius set', Level.LEVEL0, async (done: Function) => {
      const ctx = new FakeHostContext();
      const fake = new FakeWindow();
      fake.rejectCornerRadius = true;
      const host: TestAnchoredHost = new TestAnchoredHost(ctx, 6, 0, 100, 80);
      await host.styleAfterResizeForTest(fake as ESObject as window.Window);
      expect(fake.backgroundColor).assertEqual('#00000000');
      expect(fake.shadowRadius).assertEqual(0);
      done();
    });

    it('skips the shadow API when the window lacks it', Level.LEVEL0, async (done: Function) => {
      const ctx = new FakeHostContext();
      const fake = new FakeWindowNoShadow();
      const host: TestAnchoredHost = new TestAnchoredHost(ctx, 7, 0, 100, 80);
      await host.styleAfterResizeForTest(fake as ESObject as window.Window);
      expect(fake.background).assertEqual('#00000000');
      expect(fake.cornerRadius).assertEqual(0);
      done();
    });
  });

  describe('AnchoredWindowHost.placeInitial', () => {
    it('marks the host anchored on placement', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(8, 9);
        await p.host.placeInitialForTest(p.host.subWindow as ESObject as window.Window, 100, 80, 200, 160);
        expect(p.host.anchored).assertTrue();
        done();
      });
  });

  describe('AnchoredWindowHost.positionAt', () => {
    it('returns early without a sub-window', Level.LEVEL0, async (done: Function) => {
      const ctx = new FakeHostContext();
      ctx.parentAbilityFor = new FakeAbility() as ESObject as UIAbility;
      const host: TestAnchoredHost = new TestAnchoredHost(ctx, 10, 0, 100, 80);
      host.setParentForTest(ctx.parentAbilityFor);
      await host.positionAtForTest(100, 80);
      done();
    });

    it('returns early without a parent ability', Level.LEVEL0, async (done: Function) => {
      const ctx = new FakeHostContext();
      const fake = new FakeWindow();
      const host: TestAnchoredHost = new TestAnchoredHost(ctx, 11, 0, 100, 80);
      host.subWindow = fake as ESObject as window.Window;
      await host.positionAtForTest(100, 80);
      expect(fake.moveCalls.length).assertEqual(0);
      done();
    });

    it('returns early without a windowStage', Level.LEVEL0, async (done: Function) => {
      const ctx = new FakeHostContext();
      ctx.parentAbilityFor = new FakeAbility() as ESObject as UIAbility;
      const fake = new FakeWindow();
      const host: TestAnchoredHost = new TestAnchoredHost(ctx, 12, 0, 100, 80);
      host.subWindow = fake as ESObject as window.Window;
      host.setParentForTest(ctx.parentAbilityFor);
      await host.positionAtForTest(100, 80);
      expect(fake.moveCalls.length).assertEqual(0);
      done();
    });

    it('queries the native positioner and does not move when unplaced', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(13, 9);
        await p.host.positionAtForTest(100, 80);
        expect(p.mainWin.moveCalls.length).assertEqual(0);
        done();
      });

    it('prefers the parent sub-window rect when the parent is a sub-window', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(14, 9);
        const parentSub = new FakeWindow();
        parentSub.props.setWindowRect(50, 60, 400, 300);
        p.ctx.subWindows.set('9', parentSub as ESObject as window.Window);
        await p.host.positionAtForTest(100, 80);
        expect(parentSub.moveCalls.length).assertEqual(0);
        done();
      });

    it('logs when the parent main-window read throws', Level.LEVEL0, async (done: Function) => {
      const p = makePositioned(15, 9);
      p.stage.getMainThrows = true;
      await p.host.positionAtForTest(100, 80);
      expect(p.mainWin.moveCalls.length).assertEqual(0);
      done();
    });

    it('falls back to windowRect when drawableRect is unavailable', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(16, 9);
        p.mainWin.props = new DrThrowingProperties() as ESObject as FakeWindowProperties;
        await p.host.positionAtForTest(100, 80);
        expect(p.mainWin.moveCalls.length).assertEqual(0);
        done();
      });

    it('retries the resize on the next placement after a rejection', Level.LEVEL0,
      async (done: Function) => {
        // A rejected resize must NOT commit the appliedPhysW/H baseline —
        // committing it would dedupe away every later placement of the same
        // size, sticking the anchored window at its birth size forever.
        const p = makePositioned(17, 9);
        const sub = new FakeWindow();
        // Birth props 600x500 ≠ placement 1000x800 (@dpr 2) → resize due.
        sub.props.setWindowRect(0, 0, 600, 500);
        sub.rejectResize = true;
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [100, 100, 500, 400];
        await p.host.positionAtForTest(500, 400);
        await sleep(10);
        // First pass: resize attempted and rejected (logged by the funnel,
        // rethrown to positionAt) — the move on this pass is skipped too.
        expect(sub.resizeCalls.length).assertEqual(1);
        expect(sub.moveCalls.length).assertEqual(0);
        // Same size again: the baseline was never committed, so the resize
        // is re-issued instead of being skipped as "already applied".
        await p.host.positionAtForTest(500, 400);
        await sleep(10);
        expect(sub.resizeCalls.length).assertEqual(2);
        expect(sub.moveCalls.length).assertEqual(0);
        done();
      });
  });

  describe('AnchoredWindowHost.startParentTracking', () => {
    it('listens on the ability main window and flips anchored', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(20, 9);
        p.host.startParentTrackingForTest();
        expect(p.host.anchored).assertTrue();
        expect(p.mainWin.rectOnCount).assertEqual(1);
        expect(p.mainWin.rectChangeCb).not().assertUndefined();
        // The parent LIFECYCLE listener lands on the same window.
        expect(p.mainWin.windowEventCb).not().assertUndefined();
        done();
      });

    it('is idempotent while already anchored', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(21, 9);
        p.host.startParentTrackingForTest();
        p.host.startParentTrackingForTest();
        expect(p.mainWin.rectOnCount).assertEqual(1);
        done();
      });

    it('stays unanchored without a parent ability', Level.LEVEL0,
      async (done: Function) => {
        const ctx = new FakeHostContext();
        const host: TestAnchoredHost = new TestAnchoredHost(ctx, 22, 0, 100, 80);
        host.startParentTrackingForTest();
        expect(host.anchored).assertFalse();
        done();
      });

    it('stays unanchored without a windowStage', Level.LEVEL0,
      async (done: Function) => {
        const ctx = new FakeHostContext();
        ctx.parentAbilityFor = new FakeAbility() as ESObject as UIAbility;
        const host: TestAnchoredHost = new TestAnchoredHost(ctx, 23, 0, 100, 80);
        host.setParentForTest(ctx.parentAbilityFor);
        host.startParentTrackingForTest();
        expect(host.anchored).assertFalse();
        done();
      });

    it('stays unanchored when resolveParentWindow throws', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(24, 9);
        p.ctx.subWindowOfViewThrows = true;
        p.host.startParentTrackingForTest();
        expect(p.host.anchored).assertFalse();
        expect(p.mainWin.rectOnCount).assertEqual(0);
        done();
      });

    it('stays unanchored when on() throws', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(25, 9);
        p.mainWin.onThrows = true;
        p.host.startParentTrackingForTest();
        expect(p.host.anchored).assertFalse();
        done();
      });

    it('prefers the parent sub-window over the main window', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(26, 9);
        const parentSub = new FakeWindow();
        p.ctx.subWindows.set('9', parentSub as ESObject as window.Window);
        p.host.startParentTrackingForTest();
        expect(parentSub.rectOnCount).assertEqual(1);
        expect(p.mainWin.rectOnCount).assertEqual(0);
        done();
      });
  });

  describe('AnchoredWindowHost.onParentRectChanged', () => {
    it('re-anchors the host on a parent rect change', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(27, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [100, 100, 500, 400];
        // Birth placement seeds the preferred size and starts tracking.
        await p.host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
        await sleep(10); // placeInitial's positionAt settles → 1 move
        expect(sub.moveCalls.length).assertEqual(1);
        fireRectChange(p.mainWin);
        await sleep(10); // leading-edge reanchor's positionAt settles
        expect(sub.moveCalls.length).assertEqual(2);
        done();
      });

    it('keeps the listener bound to the same parent (never rebinds)', Level.LEVEL0,
      async (done: Function) => {
        // The host's lifecycle is tied to its parent: a rect event only
        // re-anchors, it never re-resolves or re-binds the listener.
        const p = makePositioned(29, 9);
        p.host.subWindow = new FakeWindow() as ESObject as window.Window;
        p.host.startParentTrackingForTest();
        fireRectChange(p.mainWin);
        expect(p.mainWin.rectOnCount).assertEqual(1);
        expect(p.mainWin.rectChangeCb).not().assertUndefined();
        done();
      });
  });

  describe('AnchoredWindowHost.parentResize', () => {
    it('keeps re-anchoring on parent moves (win32 has no WM_MOVE handling)', Level.LEVEL0,
      async (done: Function) => {
        const p = await makeAnchored(70);
        const sub = p.host.subWindow as ESObject as FakeWindow;
        const moves = sub.moveCalls.length;
        fireRectChange(p.mainWin);
        await sleep(10);
        expect(sub.moveCalls.length).assertEqual(moves + 1);
        expect(sub.destroyCount).assertEqual(0);
        expect(p.host.anchored).assertTrue();
        done();
      });

    it('destroys the host on a parent resize (win32 WM_SIZE → destroy)', Level.LEVEL0,
      async (done: Function) => {
        const p = await makeAnchored(71);
        const sub = p.host.subWindow as ESObject as FakeWindow;
        const moves = sub.moveCalls.length;
        fireParentResize(p.mainWin, 800, 600);
        expect(sub.destroyCount).assertEqual(1); // OS sub-window removed
        expect(p.host.anchored).assertFalse(); // tracking stopped
        expect(p.mainWin.rectChangeCb).assertUndefined(); // listener off'd
        expect(p.mainWin.windowEventCb).assertUndefined(); // lifecycle too
        expect(p.ctx.removedHosts.length).assertEqual(1); // bookkeeping dropped
        // Teardown never re-shows the parent (win32 DestroyWindow parity).
        expect(p.ctx.restoredForegrounds.includes('71')).assertFalse();
        await sleep(80); // no trailing reanchor sneaks in post-teardown
        expect(sub.moveCalls.length).assertEqual(moves);
        done();
      });

    it('recognizes a single-step resize when the tracking-start seed failed',
      Level.LEVEL0, async (done: Function) => {
        // seedParentSize's read at tracking start fails (transient 1300002);
        // the placement read moments later succeeds — THAT read must seed
        // the baseline, or the first event (a single-step resize: maximize /
        // snap / fold) would seed its own post-resize rect and the destroy
        // would never fire.
        const stage = new FakeWindowStage();
        const parent = new PropsFailFirstWindow();
        parent.propsFailCount = 1;
        stage.mainWindow = parent as ESObject as window.Window;
        const ctx = new FakeHostContext();
        ctx.stage = stage as ESObject as window.WindowStage;
        ctx.dpr = 2.0;
        const ability: UIAbility = new FakeAbility() as ESObject as UIAbility;
        ctx.parentAbilityFor = ability;
        const host = new TestAnchoredHost(ctx, 82, 9, 100, 80);
        const sub = new FakeWindow();
        host.subWindow = sub as ESObject as window.Window;
        host.setParentForTest(ability);
        host.workOverride = [0, 0, 2400, 1200];
        host.simulatePlacement = [100, 100, 500, 400];
        await host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
        await sleep(10); // birth placement settles
        fireParentResize(parent, 800, 600);
        expect(sub.destroyCount).assertEqual(1); // resize recognized
        expect(parent.rectChangeCb).assertUndefined(); // listeners off'd
        done();
      });
  });

  describe('AnchoredWindowHost.deactivatePolicy.win32Parity', () => {
    it('destroys IMMEDIATELY on parent WINDOW_INACTIVE (win32 WA_INACTIVE)',
      Level.LEVEL0, async (done: Function) => {
        const p = await makeAnchored(60);
        const sub = p.host.subWindow as ESObject as FakeWindow;
        p.mainWin.windowEventCb?.(window.WindowEventType.WINDOW_INACTIVE);
        expect(sub.destroyCount).assertEqual(1); // synchronous — no grace
        expect(p.ctx.removedHosts.length).assertEqual(1); // bookkeeping dropped
        // Teardown never re-shows the parent (win32 DestroyWindow parity).
        expect(p.ctx.restoredForegrounds.includes('60')).assertFalse();
        expect(p.mainWin.windowEventCb).assertUndefined(); // listeners off'd
        expect(p.host.anchored).assertFalse();
        done();
      });

    it('parent WINDOW_ACTIVE alone destroys nothing', Level.LEVEL0,
      async (done: Function) => {
        const p = await makeAnchored(61);
        const sub = p.host.subWindow as ESObject as FakeWindow;
        p.mainWin.windowEventCb?.(window.WindowEventType.WINDOW_ACTIVE);
        await sleep(80); // prove no deferred close either
        expect(sub.destroyCount).assertEqual(0);
        expect(p.host.anchored).assertTrue();
        done();
      });

    it('one-shot guard: a stray repeat of the captured callback closes once',
      Level.LEVEL0, async (done: Function) => {
        const p = await makeAnchored(62);
        const sub = p.host.subWindow as ESObject as FakeWindow;
        const cb = p.mainWin.windowEventCb; // captured pre-teardown
        cb?.(window.WindowEventType.WINDOW_INACTIVE);
        cb?.(window.WindowEventType.WINDOW_INACTIVE); // teardown noise repeat
        await sleep(80);
        expect(sub.destroyCount).assertEqual(1);
        expect(p.ctx.removedHosts.length).assertEqual(1);
        done();
      });

    it('destroys on parent WINDOW_DESTROYED (orphan guard)', Level.LEVEL0,
      async (done: Function) => {
        const p = await makeAnchored(83);
        const sub = p.host.subWindow as ESObject as FakeWindow;
        // WINDOW_DESTROYED is the LAST thing a destroyed parent's listeners
        // receive — no later INACTIVE, no further rect event. A popup parent
        // (never active → never INACTIVE) must still take its anchored
        // children down, or the non-focusable host is orphaned on screen.
        const cb = p.mainWin.windowEventCb; // captured pre-teardown
        cb?.(window.WindowEventType.WINDOW_DESTROYED);
        expect(sub.destroyCount).assertEqual(1); // OS sub-window removed
        expect(p.ctx.removedHosts.length).assertEqual(1); // bookkeeping dropped
        expect(p.ctx.restoredForegrounds.includes('83')).assertFalse();
        expect(p.mainWin.windowEventCb).assertUndefined(); // listeners off'd
        expect(p.mainWin.rectChangeCb).assertUndefined();
        expect(p.host.anchored).assertFalse();
        cb?.(window.WindowEventType.WINDOW_DESTROYED); // teardown noise repeat
        expect(sub.destroyCount).assertEqual(1); // one-shot held
        done();
      });

    it('a Dart-initiated destroy never re-shows the parent either', Level.LEVEL0,
      async (done: Function) => {
        const p = await makeAnchored(63);
        const sub = p.host.subWindow as ESObject as FakeWindow;
        p.host.destroy();
        expect(sub.destroyCount).assertEqual(1);
        // Anchored closeHost override: NO parent re-show on ANY path.
        expect(p.ctx.restoredForegrounds.length).assertEqual(0);
        done();
      });
  });

  describe('AnchoredWindowHost.prepareShow', () => {
    it('makes the host non-focusable (win32 NOACTIVATE parity)', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(64, 9);
        const sub = new FakeWindow();
        await p.host.prepareShowForTest(sub as ESObject as window.Window);
        expect(sub.focusable).assertFalse();
        done();
      });

    it('logs a rejected focusable set and continues', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(65, 9);
        const sub = new FakeWindow();
        sub.rejectFocusable = true;
        await p.host.prepareShowForTest(sub as ESObject as window.Window);
        expect(sub.focusable).assertTrue();
        done();
      });
  });

  describe('AnchoredWindowHost.throttledReanchor', () => {
    it('coalesces a burst into one leading + one trailing reanchor', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(32, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [100, 100, 500, 400];
        await p.host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
        await sleep(10); // placeInitial settles → baseline of 1 move
        fireRectChange(p.mainWin); // leading edge runs now
        await sleep(10);
        expect(sub.moveCalls.length).assertEqual(2);
        fireRectChange(p.mainWin); // within 50ms: arms ONE trailing timer
        fireRectChange(p.mainWin); // dropped: a timer is already pending
        expect(sub.moveCalls.length).assertEqual(2);
        await sleep(80); // > kMoveThrottleMs(50): flush the trailing edge
        expect(sub.moveCalls.length).assertEqual(3);
        // Reanchors place for the preferred size: the sub's live geometry
        // is read ONCE (placeInitial's seed), never per reanchor.
        expect(sub.propsReads).assertEqual(1);
        done();
      });

    it('applies the final resting position via the trailing edge', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(33, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [100, 100, 500, 400];
        await p.host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
        await sleep(10);
        fireRectChange(p.mainWin); // leading edge
        fireRectChange(p.mainWin); // arms the trailing edge
        await sleep(80);
        // Trailing timer fired after the burst ended: birth move + 2 re-anchors.
        expect(sub.moveCalls.length).assertEqual(3);
        done();
      });
  });

  describe('AnchoredWindowHost.stopParentTracking', () => {
    it('releases the listener and clears anchored on destroy', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(34, 9);
        p.host.startParentTrackingForTest();
        expect(p.mainWin.rectChangeCb).not().assertUndefined();
        p.host.destroy();
        expect(p.host.anchored).assertFalse();
        expect(p.mainWin.rectChangeCb).assertUndefined();
        expect(p.mainWin.windowEventCb).assertUndefined();
        expect(p.ctx.removedHosts.length).assertEqual(1);
        done();
      });

    it('cancels a pending trailing reanchor', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(35, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [100, 100, 500, 400];
        await p.host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
        await sleep(10);
        fireRectChange(p.mainWin); // leading edge runs
        await sleep(10);
        fireRectChange(p.mainWin); // trailing timer armed
        expect(sub.moveCalls.length).assertEqual(2);
        p.host.destroy();
        await sleep(80);
        expect(sub.moveCalls.length).assertEqual(2); // no post-teardown reanchor
        done();
      });

    it('survives an off() throw during teardown', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(36, 9);
        p.host.startParentTrackingForTest();
        p.mainWin.offThrows = true;
        p.host.destroy();
        expect(p.host.anchored).assertFalse();
        done();
      });

    it('is idempotent across repeated teardown', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(37, 9);
        p.host.startParentTrackingForTest();
        p.host.destroy();
        p.host.destroy();
        expect(p.host.anchored).assertFalse();
        done();
      });
  });

  describe('AnchoredWindowHost.reanchor', () => {
    it('no-ops while not anchored (teardown gate)', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(38, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.reanchor(); // never placed / already torn down
        expect(sub.propsReads).assertEqual(0);
        done();
      });

    it('no-ops without a sub-window', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(39, 9);
        p.host.startParentTrackingForTest();
        // startParentTracking seeds the move/resize baseline with ONE
        // getWindowProperties() read; reanchor itself must add none.
        const readsAfterSeed = p.mainWin.propsReads;
        p.host.subWindow = undefined;
        p.host.reanchor();
        expect(p.mainWin.propsReads).assertEqual(readsAfterSeed); // parent not consulted
        done();
      });

    it('re-places at the preferred size, growing back after a shrink', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(40, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [700, 300, 100, 80]; // shrunk at a screen edge
        await p.host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
        expect(sub.resizeCalls.length).assertEqual(1); // 1000x800 → 200x160
        p.host.simulatePlacement = [100, 100, 500, 400]; // constraint lifted
        p.host.reanchor();
        await sleep(10); // positionAt's promise settles
        // reanchor asked for the PREFERRED size (500x400 logical), never
        // the shrunken live rect (100x80) — the compression stays transient.
        expect(p.host.placementArgs[0]).assertEqual(500);
        expect(p.host.placementArgs[1]).assertEqual(400);
        expect(sub.resizeCalls.length).assertEqual(2); // grew back
        expect(sub.resizeCalls[1][0]).assertEqual(1000);
        expect(sub.resizeCalls[1][1]).assertEqual(800);
        done();
      });

    it('no-ops before placeInitial seeds the preferred size', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(41, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [100, 100, 500, 400];
        p.host.startParentTrackingForTest();
        p.host.reanchor(); // anchored, sub present, but preferred unset
        await sleep(10);
        expect(sub.moveCalls.length).assertEqual(0);
        expect(p.host.anchored).assertTrue();
        done();
      });
  });

  describe('AnchoredWindowHost.reanchor.serialization', () => {
    it('pends the trailing edge while an animated resize is in flight (no duplicate resize)', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(70, 9);
        const sub = new GatedResizeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [700, 300, 100, 80]; // shrunken target
        await p.host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
        expect(sub.resizeCalls.length).assertEqual(1); // birth: 1000x800 → 200x160

        sub.gateOpen = false; // resizes park from here (animated, >50ms)
        p.host.simulatePlacement = [100, 100, 500, 400]; // constraint lifts
        fireRectChange(p.mainWin); // leading edge → flight parks in resize()
        await sleep(10);
        fireRectChange(p.mainWin); // arms ONE trailing timer
        await sleep(80); // it fires while the flight is STILL parked
        // The regression: the trailing reanchor must not have read a stale
        // appliedPhysW/H and re-issued the in-flight resize.
        expect(sub.resizeCalls.length).assertEqual(2); // birth + flight

        sub.openGate(); // resize settles → flight completes, drain runs once
        await sleep(10);
        // One size change → exactly ONE resize for it; the drained flight
        // re-places for the preferred size and the guard now sees it applied.
        expect(sub.resizeCalls.length).assertEqual(2);
        expect(sub.moveCalls.length).assertEqual(3); // birth + flight + drain
        done();
      });

    it('holds the birth placement against an immediate leading-edge reanchor', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(71, 9);
        const sub = new GatedResizeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [700, 300, 100, 80]; // shrunken target
        sub.gateOpen = false; // the birth resize itself parks
        const placed: Promise<void> =
          p.host.placeInitialForTest(sub as ESObject as window.Window, 500, 400, 1000, 800);
        // Tracking is live while the birth placement parks in resize(): a
        // parent move now fires a leading-edge reanchor that must PEND.
        fireRectChange(p.mainWin);
        await sleep(10);
        expect(sub.resizeCalls.length).assertEqual(1); // birth only, no dupe

        sub.openGate(); // birth flight settles → the pended reanchor drains
        await placed;
        await sleep(10);
        // The drain re-places through reanchor()'s front door: same target
        // (positioner result unchanged) → guard skips, move only.
        expect(sub.resizeCalls.length).assertEqual(1);
        expect(sub.moveCalls.length).assertEqual(2); // birth + drained
        done();
      });
  });

  describe('AnchoredWindowHost.positionAt.sizing', () => {
    // Shared setup: parent = ability main window (1000x800 phys at 0,0,
    // dpr 2 → 500x400 logical content); sub = DISTINCT FakeWindow whose
    // live rect is also 1000x800 phys.
    it('applies the positioner-shrunken size before moving', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(50, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [700, 300, 100, 80]; // logical, shrunk
        await p.host.positionAtForTest(500, 400);
        // dpr 2: target 200x160 phys vs live 1000x800 → resize once, then move.
        expect(sub.resizeCalls.length).assertEqual(1);
        expect(sub.resizeCalls[0][0]).assertEqual(200);
        expect(sub.resizeCalls[0][1]).assertEqual(160);
        expect(sub.moveCalls.length).assertEqual(1);
        expect(sub.moveCalls[0][0]).assertEqual(1400);
        expect(sub.moveCalls[0][1]).assertEqual(600);
        done();
      });

    it('does not resize when the positioner keeps the window size', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(51, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [100, 100, 500, 400]; // live logical size
        await p.host.positionAtForTest(500, 400);
        expect(sub.resizeCalls.length).assertEqual(0);
        expect(sub.moveCalls.length).assertEqual(1);
        expect(sub.moveCalls[0][0]).assertEqual(200);
        expect(sub.moveCalls[0][1]).assertEqual(200);
        done();
      });

    it('issues resize once across repeated identical placements', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(52, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [700, 300, 100, 80];
        await p.host.positionAtForTest(500, 400);
        // A repeat placement at the now-applied size (e.g. a parent-move
        // burst while pinned at the edge) must not re-issue the resize.
        await p.host.positionAtForTest(100, 80);
        expect(sub.resizeCalls.length).assertEqual(1);
        expect(sub.moveCalls.length).assertEqual(2);
        done();
      });

    it('skips degenerate sizes and still moves', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(53, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [50, 50, 0, 80]; // width collapses to 0
        await p.host.positionAtForTest(500, 400);
        expect(sub.resizeCalls.length).assertEqual(0);
        expect(sub.moveCalls.length).assertEqual(1);
        done();
      });

    it('applies the target size when the live size cannot be read', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(54, 9);
        const sub = new ThrowingPropsWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 0, 2400, 1200];
        p.host.simulatePlacement = [700, 300, 100, 80];
        await p.host.positionAtForTest(500, 400);
        // Baseline seeding failed → target applied unconditionally.
        expect(sub.resizeCalls.length).assertEqual(1);
        expect(sub.resizeCalls[0][0]).assertEqual(200);
        expect(sub.resizeCalls[0][1]).assertEqual(160);
        done();
      });

    it('passes the work area through to the positioner', Level.LEVEL0,
      async (done: Function) => {
        const p = makePositioned(55, 9);
        const sub = new FakeWindow();
        p.host.subWindow = sub as ESObject as window.Window;
        p.host.workOverride = [0, 40, 2400, 1160]; // physical: 40px band excluded
        p.host.simulatePlacement = [10, 10, 100, 80];
        await p.host.positionAtForTest(500, 400);
        // Logical work area: 0, 20, 1200, 580 (÷ dpr 2).
        expect(p.host.placementArgs[6]).assertEqual(0);
        expect(p.host.placementArgs[7]).assertEqual(20);
        expect(p.host.placementArgs[8]).assertEqual(1200);
        expect(p.host.placementArgs[9]).assertEqual(580);
        done();
      });
  });

}
