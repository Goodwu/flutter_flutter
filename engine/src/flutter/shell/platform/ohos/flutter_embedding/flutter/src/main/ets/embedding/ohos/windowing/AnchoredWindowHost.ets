/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import window from '@ohos.window';
import display from '@ohos.display';
import Log from '../../../util/Log';
import FlutterNapi, { WindowPositionResult } from '../../engine/FlutterNapi';
import { WindowArchetype } from './WindowArchetype';
import { WindowHostContext } from './WindowHostContext';
import { SubWindowHost } from './SubWindowHost';

const TAG = 'AnchoredWindowHost'

/** setWindowShadowRadius — dynamic @since 17, static @since 23; not on the
 * API-12 Window typedef this embedding compiles against. */
interface WindowShadowRadiusApi {
  setWindowShadowRadius(radius: number): void;
}

/**
 * Positioner-anchored sub-window host (tooltip/popup). The window keeps its
 * launch size — OHOS resize is animated and cannot track per-frame content.
 */
export abstract class AnchoredWindowHost extends SubWindowHost {
  /** True while this host is tracking its parent's moves (set in
   * startParentTracking, cleared in stopParentTracking). Gates reanchor
   * after teardown — this.subWindow is NOT cleared on teardown paths. */
  anchored: boolean = false;

  constructor(ctx: WindowHostContext,
              viewId: number,
              parentViewId: number,
              archetype: WindowArchetype,
              width: number,
              height: number) {
    super(ctx, viewId, parentViewId, archetype, width, height);
  }

  // ---- Parent-move tracking ----------------------------------------------
  // The host listens on its OWN parent window (the parent view's sub-window
  // when there is one, the ability main window otherwise) so a drag of the
  // parent re-anchors this window. One listener + one throttle per host,
  // bound once at startParentTracking and released at stopParentTracking:
  // this auxiliary window's lifecycle is tied to that parent, so the
  // listener never moves to another window.

  /** ~20Hz throttle: windowRectChange streams during a drag; sub-window
   * moves are unanimated. */
  private static readonly kMoveThrottleMs = 50;
  /** The parent window listened on from startParentTracking until stop. */
  private trackedParentWin: window.Window | undefined = undefined;
  /** Stable arrow so off() always hands back the same reference (FlutterView
   * uses the same idiom for its windowRectChange callback). */
  private parentRectCallback = (data: window.RectChangeOptions): void => {
    this.onParentRectChanged(data);
  };
  // Leading-edge timestamp + trailing-edge flag of the throttle.
  private lastMoveForward: number = 0;
  private trailingTimer?: number;

  /**
   * The window this host anchors against: the parent view's OWN sub-window
   * when it has one (tooltip inside a dialog → the dialog's window; the
   * hosting ability's main window is a different screen rect entirely), the
   * ability main window otherwise. Protected: placement (positionAt)
   * resolves it per call; parent tracking binds it once at start.
   */
  protected resolveParentWindow(): window.Window | undefined {
    const parentAbility = this.parentAbility;
    if (!parentAbility) {
      return undefined;
    }
    const windowStage = this.ctx.windowStageOf(parentAbility);
    if (!windowStage) {
      return undefined;
    }
    try {
      const parentSub = this.ctx.subWindowOfView(String(this.parentViewId));
      if (parentSub !== undefined) {
        return parentSub;
      }
      return windowStage.getMainWindowSync();
    } catch (e) {
      Log.w(TAG, `resolveParentWindow failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
      return undefined;
    }
  }

  /** Starts following the parent's moves (idempotent; never throws).
   * anchored flips true only when the listener actually landed. */
  protected startParentTracking(): void {
    if (this.anchored) {
      return;
    }
    const parentWin = this.resolveParentWindow();
    if (!parentWin) {
      Log.w(TAG, `startParentTracking: no parent window yet for ${this.viewIdStr}`);
      return;
    }
    try {
      parentWin.on('windowRectChange', this.parentRectCallback);
    } catch (e) {
      Log.w(TAG, `startParentTracking: windowRectChange on() failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
      return;
    }
    this.trackedParentWin = parentWin;
    this.anchored = true;
  }

  private onParentRectChanged(data: window.RectChangeOptions): void {
    this.throttledReanchor();
  }

  /**
   * Leading-edge throttle with a trailing edge: events within
   * [kMoveThrottleMs] are dropped EXCEPT one deferred run, so the final
   * resting position after a drag burst is always applied.
   */
  private throttledReanchor(): void {
    const now = Date.now();
    const elapsed = now - this.lastMoveForward;
    if (elapsed >= AnchoredWindowHost.kMoveThrottleMs) {
      this.lastMoveForward = now;
      this.reanchor();
      return;
    }
    if (this.trailingTimer !== undefined) {
      return;
    }
    this.trailingTimer = setTimeout((): void => {
      this.trailingTimer = undefined;
      this.lastMoveForward = Date.now();
      this.reanchor();
    }, AnchoredWindowHost.kMoveThrottleMs - elapsed) as number;
  }

  /** Stops following the parent (idempotent) — every teardown path lands
   * here via the cleanupBookkeeping override. */
  private stopParentTracking(): void {
    this.anchored = false;
    if (this.trailingTimer !== undefined) {
      clearTimeout(this.trailingTimer);
      this.trailingTimer = undefined;
    }
    const tracked = this.trackedParentWin;
    this.trackedParentWin = undefined;
    if (tracked !== undefined) {
      try {
        tracked.off('windowRectChange', this.parentRectCallback);
      } catch (e) {
        Log.w(TAG, `stopParentTracking: off() failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
      }
    }
  }

  /** Releases the parent listener before the shared bookkeeping drop. */
  protected cleanupBookkeeping(): void {
    this.stopParentTracking();
    super.cleanupBookkeeping();
  }

  // ---- Launch styling: transparent / shadowless / square -----------------

  /**
   * Kill the "white flash/edge": OHOS windows default to an opaque
   * '#FFF0F0F0' background that shows through the transparent parts of the
   * Flutter content, so the host must be fully transparent
   * (Regular/Dialog/Satellite keep an opaque host).
   */
  protected async styleAfterResize(subWindow: window.Window): Promise<void> {
    try {
      subWindow.setWindowBackgroundColor('#00000000');
    } catch (e) {
      Log.w(TAG, `subWindow setWindowBackgroundColor failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
    }
    try {
      const shadowApi = subWindow as WindowShadowRadiusApi;
      if (typeof shadowApi.setWindowShadowRadius === 'function') {
        shadowApi.setWindowShadowRadius(0);
      }
    } catch (e) {
      Log.w(TAG, `subWindow setWindowShadowRadius failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
    }
    try {
      await subWindow.setWindowCornerRadius(0);
    } catch (e) {
      Log.w(TAG, `subWindow setWindowCornerRadius failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
    }
  }

  // ---- Initial placement: Dart positioner ---------------------------------

  /** Anchors the window to its triggering widget via the Dart positioner. */
  protected async placeInitial(subWindow: window.Window,
                                        logicalW: number,
                                        logicalH: number,
                                        physW: number,
                                        physH: number): Promise<void> {
    // Follow the parent from here on; resolveParentWindow picks the dialog's
    // sub-window over the ability main window when the parent has one.
    this.startParentTracking();
    await this.positionAt(logicalW, logicalH);
  }

  // ---- Anchoring -----------------------------------------------------------

  /**
   * Moves the window to the Dart positioner's LOGICAL position
   * (moveWindowTo takes PHYSICAL px ×dpr). The parent's screen geometry
   * lives only here, hence the nativeComputeWindowPosition round trip.
   * Fully guarded — never throws (both call sites rely on that).
   */
  protected async positionAt(logicalW: number, logicalH: number): Promise<void> {
    const subWindow = this.subWindow;
    if (!subWindow) {
      Log.w(TAG, `positionAt: no subWindow for viewId=${this.viewIdStr}`);
      return;
    }
    const parentWin = this.resolveParentWindow();
    if (!parentWin) {
      Log.w(TAG, `positionAt: no parent window for viewId=${this.viewIdStr}`);
      return;
    }
    try {
      const dpr = this.ctx.densityPixels();
      const wr = parentWin.getWindowProperties().windowRect; // physical px
      // windowRect is the DECORATED rect (origin above the caption) while
      // Dart's anchorRect origin is the CONTENT top-left — translating by
      // windowRect.origin alone places every anchor one caption-height too
      // high. Use drawableRect (content area relative to the window's
      // top-left, API 11+); fallback: treat the window as undecorated.
      let drLeft = 0;
      let drTop = 0;
      let drW = wr.width;
      let drH = wr.height;
      try {
        const dr = parentWin.getWindowProperties().drawableRect;
        drLeft = dr.left; drTop = dr.top; drW = dr.width; drH = dr.height;
      } catch (_) { /* keep windowRect as-is */ }
      const disp = display.getDefaultDisplaySync();
      const pos = new WindowPositionResult();
      // Invoke the positioner with the WINDOW's logical size so the host
      // lands exactly where the positioner says the window belongs.
      const ret = FlutterNapi.nativeComputeWindowPosition(
        pos, this.viewId,
        logicalW, logicalH,
        (wr.left + drLeft) / dpr, (wr.top + drTop) / dpr, // content-origin (logical)
        drW / dpr, drH / dpr, // parent content size (logical)
        0, 0, disp.width / dpr, disp.height / dpr); // workArea=display (logical)
      if (ret === 0) {
        const px = Math.round(pos.left * dpr);
        const py = Math.round(pos.top * dpr);
        await subWindow.moveWindowToAsync(px, py);
      }
    } catch (e) {
      Log.w(TAG, `subWindow position compute/move failed ` +
        `for viewId=${this.viewIdStr}: ${JSON.stringify(e)}`);
    }
  }

  /** Parent moved → re-anchor at the current size; rate limiting is
   * per-host (throttledReanchor). */
  reanchor(): void {
    if (!this.anchored) {
      return;
    }
    const sub = this.subWindow;
    if (!sub) {
      return;
    }
    try {
      const dpr = this.ctx.densityPixels();
      const rect = sub.getWindowProperties().windowRect; // physical
      this.positionAt(rect.width / dpr, rect.height / dpr).catch((e: Object) => {
        Log.w(TAG, `reanchor failed viewId=${this.viewIdStr}: ${JSON.stringify(e)}`);
      });
    } catch (e) {
      Log.w(TAG, `reanchor geometry read failed viewId=${this.viewIdStr}: ${JSON.stringify(e)}`);
    }
  }
}
