/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { describe, expect, it, Level } from '@ohos/hypium';
import window from '@ohos.window';
import { PopupWindowHost } from
  '../../../../../../main/ets/embedding/ohos/windowing/PopupWindowHost';
import { WindowArchetype } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowArchetype';
import { WindowHostContext } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowHostContext';
import { FlutterView } from '../../../../../../main/ets/view/FlutterView';
import { FakeWindow, FakeFlutterView, FakeHostContext, sleep } from './Fakes';

/** Concrete subclass exposing the protected deactivate-policy hooks. */
class TestPopupHost extends PopupWindowHost {
  constructor(ctx: WindowHostContext, viewId: number, parentViewId: number, w: number, h: number) {
    super(ctx, viewId, parentViewId, w, h);
  }

  ownActiveForTest(): void {
    this.onSubWindowActivated();
  }

  ownInactiveForTest(): void {
    this.onSubWindowDeactivated();
  }

  parentActiveForTest(): void {
    this.onParentWindowEvent(window.WindowEventType.WINDOW_ACTIVE);
  }

  parentInactiveForTest(): void {
    this.onParentWindowEvent(window.WindowEventType.WINDOW_INACTIVE);
  }

  async prepareShowForTest(subWindow: window.Window): Promise<void> {
    await this.prepareShow(subWindow);
  }
}

/** Popup + own sub-window bundle (parent view 9; fv registered for detach). */
class PopupSetup {
  ctx: FakeHostContext;
  fake: FakeWindow;
  host: TestPopupHost;

  constructor(viewId: number) {
    const ctx = new FakeHostContext();
    ctx.flutterViews.set(String(viewId), new FakeFlutterView() as ESObject as FlutterView);
    const fake = new FakeWindow();
    const host = new TestPopupHost(ctx, viewId, 9, 100, 80);
    host.subWindow = fake as ESObject as window.Window;
    this.ctx = ctx;
    this.fake = fake;
    this.host = host;
  }
}

export default function popupWindowHostTest() {
  describe('PopupWindowHost.constructor', () => {
    it('passes the POPUP archetype', Level.LEVEL0, () => {
      const ctx: WindowHostContext = new FakeHostContext();
      const host: PopupWindowHost = new PopupWindowHost(ctx, 1, 0, 100, 80);
      expect(host.archetype).assertEqual(WindowArchetype.POPUP);
      expect(host.viewId).assertEqual(1);
      expect(host.parentViewId).assertEqual(0);
    });
  });

  describe('PopupWindowHost.deactivatePolicy.win32Parity', () => {
    it('destroys IMMEDIATELY on parent WINDOW_INACTIVE (win32 WA_INACTIVE)',
      Level.LEVEL0, async (done: Function) => {
        const p = new PopupSetup(2);
        // Grab the view BEFORE the destroy path: cleanupBookkeeping deletes
        // it from ctx.flutterViews, so a post-destroy get() returns undefined.
        const fv = p.ctx.flutterViews.get('2') as ESObject as FakeFlutterView;
        p.host.parentInactiveForTest();
        // Synchronous, zero grace — the popup is non-focusable, so the
        // parent's INACTIVE can never be self-caused (win32 NOACTIVATE).
        expect(p.fake.destroyCount).assertEqual(1);
        expect(p.ctx.removedHosts.includes('2')).assertTrue();
        expect(fv.detachCalls).assertEqual(1); // view detached from engine
        done();
      });

    it('own ACTIVE/INACTIVE and parent ACTIVE destroy nothing', Level.LEVEL0,
      async (done: Function) => {
        const p = new PopupSetup(3);
        p.host.ownActiveForTest();
        p.host.ownInactiveForTest(); // base pushes the flag only — never a close
        p.host.parentActiveForTest();
        await sleep(80); // prove no deferred close either
        expect(p.fake.destroyCount).assertEqual(0);
        expect(p.ctx.removedHosts.length).assertEqual(0);
        done();
      });

    it('policy close never re-shows the parent (win32 DestroyWindow parity)',
      Level.LEVEL0, async (done: Function) => {
        const p = new PopupSetup(4);
        p.host.parentInactiveForTest();
        // A stray showWindow would STEAL focus from its new holder —
        // that re-show was the v2.1 "second click closes" root cause.
        expect(p.ctx.restoredForegrounds.length).assertEqual(0);
        done();
      });

    it('a Dart-initiated destroy does NOT re-show the parent either',
      Level.LEVEL0, async (done: Function) => {
        const p = new PopupSetup(5);
        p.host.destroy(); // e.g. the framework closed the popup itself
        expect(p.fake.destroyCount).assertEqual(1);
        // Non-focusable host: it never took the parent's foreground.
        expect(p.ctx.restoredForegrounds.length).assertEqual(0);
        done();
      });

    it('stray parent INACTIVE repeats close exactly once (one-shot)',
      Level.LEVEL0, async (done: Function) => {
        const p = new PopupSetup(6);
        p.host.parentInactiveForTest();
        p.host.parentInactiveForTest(); // teardown noise repeat
        await sleep(80);
        expect(p.fake.destroyCount).assertEqual(1);
        expect(p.ctx.removedHosts.length).assertEqual(1);
        done();
      });
  });

  describe('PopupWindowHost.prepareShow', () => {
    it('makes the popup non-focusable (win32 NOACTIVATE parity)', Level.LEVEL0,
      async (done: Function) => {
        const p = new PopupSetup(7);
        await p.host.prepareShowForTest(p.fake as ESObject as window.Window);
        expect(p.fake.focusable).assertFalse();
        done();
      });

    it('logs a rejected focusable set and continues', Level.LEVEL0,
      async (done: Function) => {
        const p = new PopupSetup(8);
        p.fake.rejectFocusable = true;
        await p.host.prepareShowForTest(p.fake as ESObject as window.Window);
        expect(p.fake.focusable).assertTrue(); // unchanged default
        done();
      });
  });
}
