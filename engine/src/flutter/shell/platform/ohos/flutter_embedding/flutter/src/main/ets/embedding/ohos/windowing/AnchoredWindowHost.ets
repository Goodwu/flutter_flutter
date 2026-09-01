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

/** Mutable work-area out-param in PHYSICAL px (ArkTS-safe: class fields,
 * no object literals). */
export class WorkArea {
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;
}

/**
 * Positioner-anchored sub-window host (tooltip/popup). The window keeps its
 * launch size except while the positioner's constraint adjustment
 * (resizeX/resizeY) shrinks it to stay on screen — positionAt applies that
 * reduced size before the move, mirroring win32's
 * SetWindowPos(left, top, width, height). The preferred (launch) size is
 * remembered, so reanchoring after the constraint lifts grows the window
 * back — same as win32, whose UpdatePosition always re-places for the
 * preferred width_/height_, never the constrained rect.
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
  // this auxiliary window's lifecycle is tied to that parent (resized,
  // deactivated or destroyed → close), so the listener never moves to
  // another window.

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
  /** Stable arrow for the parent's windowEvent (lifecycle) subscription —
   * same off()-reference idiom as parentRectCallback. */
  private parentWindowEventCallback = (event: window.WindowEventType): void => {
    this.onParentWindowEvent(event);
  };
  // Leading-edge timestamp + trailing-edge flag of the throttle.
  private lastMoveForward: number = 0;
  private trailingTimer?: number;

  /** True while a positionAt round-trip (birth placement or a reanchor
   * flight) is in flight — reanchor requests arriving meanwhile only set
   * reanchorPending. Guards the resize dedup: appliedPhysW/H are written
   * only AFTER the awaited resize settles, so a second positionAt racing
   * an in-flight one reads a stale guard and re-issues resize() — and a
   * repeated resize restarts OHOS's animated resize (never settles). The
   * animated resize can outlast the 50ms throttle window, which is exactly
   * when the trailing edge used to sneak in. */
  private positioning: boolean = false;
  /** A reanchor was requested during a flight; exactly ONE deferred run
   * follows the in-flight one — the trailing edge's "final resting
   * position is always applied" guarantee survives serialization. */
  private reanchorPending: boolean = false;

  /** Baseline parent size (PHYSICAL px, same unit as windowRectChange's
   * rect) used to tell a parent MOVE (re-anchor) from a parent RESIZE
   * (destroy). windowRectChange carries no "why" — the size delta is the
   * only discriminator. Undefined until seeded: at tracking start from the
   * live parent, else by the first event. */
  private parentPhysW: number | undefined = undefined;
  private parentPhysH: number | undefined = undefined;

  /** Last size (PHYSICAL px) this host applied via resize(); undefined
   * until first seeded from the live window. Gates reanchor's ~20Hz
   * stream: an unchanged target never re-issues (animated) resize. */
  private appliedPhysW: number | undefined = undefined;
  private appliedPhysH: number | undefined = undefined;

  /** Preferred (birth) LOGICAL size the positioner should place for — set
   * in placeInitial. win32's HostWindowTooltip keeps the same in
   * width_/height_: the positioner ALWAYS sees the preferred size, never
   * the constrained one, so resizeX/resizeY shrinks the window only while
   * the screen-edge constraint lasts and it grows back when the parent
   * returns. Feeding reanchor the live (possibly shrunken) rect instead
   * would freeze the compression. If size-to-content ever lands here,
   * update these from the content-size callback (win32's
   * DidUpdateViewSize). */
  private preferredLogicalW: number = 0;
  private preferredLogicalH: number = 0;

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
    try {
      parentWin.on('windowEvent', this.parentWindowEventCallback);
    } catch (e) {
      Log.w(TAG, `startParentTracking: windowEvent on() failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
    }
    this.anchored = true;
    this.seedParentSize(parentWin);
  }

  /** Snapshots the parent's current size as the move/resize baseline
   * (best-effort: unreadable → the first rect event seeds it instead). */
  private seedParentSize(parentWin: window.Window): void {
    try {
      const wr = parentWin.getWindowProperties().windowRect;
      this.parentPhysW = Math.round(wr.width);
      this.parentPhysH = Math.round(wr.height);
    } catch (_) { /* props unavailable → next event seeds the baseline */ }
  }

  private onParentRectChanged(data: window.RectChangeOptions): void {
    // Size delta = resize. First event without a baseline only seeds it
    // (nothing to compare against — treat as a move, the harmless default).
    const r = data.rect;
    const w = Math.round(r.width);
    const h = Math.round(r.height);
    if (this.parentPhysW === undefined || this.parentPhysH === undefined) {
      this.parentPhysW = w;
      this.parentPhysH = h;
    } else if (w !== this.parentPhysW || h !== this.parentPhysH) {
      this.closeForParentResize();
      return;
    }
    this.throttledReanchor();
  }

  protected onParentWindowEvent(event: window.WindowEventType): void {
    if (event === window.WindowEventType.WINDOW_DESTROYED) {
      this.closeForPolicy('parent destroyed (orphan guard)');
      return;
    }
    if (event === window.WindowEventType.WINDOW_INACTIVE) {
      this.closeForPolicy('parent deactivated (win32 WA_INACTIVE → destroy)');
    }
  }

  /**
   * Parent resized → destroy this window (win32 parity: parent WM_SIZE →
   * destroy in BOTH the popup and tooltip controllers — maximize/restore
   * included). Teardown chain and one-shot guard: closeForPolicy.
   */
  private closeForParentResize(): void {
    this.closeForPolicy('parent resized (win32 WM_SIZE → destroy)');
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

  /** Popup and tooltip hosts NEVER take focus. Pointer interaction still
   * works; keyboard/IME stay with the parent — the same trade-off win32's
   * NOACTIVATE popups ship with. Must land BEFORE showWindow (the
   * attach() order runs prepareShow there). */
  protected async prepareShow(subWindow: window.Window): Promise<void> {
    try {
      await subWindow.setWindowFocusable(false);
    } catch (e) {
      Log.w(TAG, `subWindow setWindowFocusable failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
    }
  }

  /** ALL anchored teardown paths skip the parent re-show (win32 parity:
   * DestroyWindow never touches the parent's activation). A non-focusable
   * host never took the parent's foreground, so there is nothing to hand
   * back — and a stray showWindow would STEAL the focus from wherever the
   * user actually moved it. */
  protected closeHost(): void {
    super.closeHost(false);
  }

  /** Stops following the parent (idempotent) — every teardown path lands
   * here via the cleanupBookkeeping override. */
  private stopParentTracking(): void {
    this.anchored = false;
    this.reanchorPending = false;
    this.parentPhysW = undefined;
    this.parentPhysH = undefined;
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
      try {
        tracked.off('windowEvent', this.parentWindowEventCallback);
      } catch (e) {
        Log.w(TAG, `stopParentTracking: windowEvent off() failed for ${this.viewIdStr}: ${JSON.stringify(e)}`);
      }
    }
  }

  /** Releases the parent listener before the shared bookkeeping drop. */
  protected cleanupBookkeeping(): void {
    this.stopParentTracking();
    super.cleanupBookkeeping();
  }

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
    this.preferredLogicalW = logicalW;
    this.preferredLogicalH = logicalH;
    this.positioning = true;
    // Follow the parent from here on; resolveParentWindow picks the dialog's
    // sub-window over the ability main window when the parent has one.
    this.startParentTracking();
    try {
      await this.positionAt(logicalW, logicalH);
    } finally {
      this.positioning = false;
    }
    if (this.reanchorPending) {
      this.reanchorPending = false;
      this.reanchor();
    }
  }

  // ---- Anchoring -----------------------------------------------------------

  /** True once workAreaPhysical logged a fallback — it runs per reanchor
   * (~20Hz during a drag), and a persistently degraded device must not
   * flood hilog; the FIRST fallback is what diagnosis needs. */
  private workAreaFallbackLogged: boolean = false;

  /**
   * Screen work area in PHYSICAL px — the available area (excludes the
   * 2in1 dock/taskbar), the same region GTK's workarea and win32's
   * SPI_GETWORKAREA use for constraint testing. getAvailableArea is
   * @since 12 and only meaningful on PC/2in1 & tablet (exactly where
   * windowing is gated); it throws elsewhere → full display, which is all
   * a phone has anyway. Protected seam: tests override to a known rect.
   */
  protected async workAreaPhysical(out: WorkArea, disp: display.Display): Promise<void> {
    try {
      const wa = await disp.getAvailableArea();
      if (wa.width > 0 && wa.height > 0) {
        out.left = wa.left;
        out.top = wa.top;
        out.width = wa.width;
        out.height = wa.height;
        return;
      }
      if (!this.workAreaFallbackLogged) {
        this.workAreaFallbackLogged = true;
        Log.w(TAG, `getAvailableArea returned degenerate ${wa.width}x${wa.height} ` +
          `for ${this.viewIdStr}; constraining against the FULL display instead`);
      }
    } catch (e) {
      if (!this.workAreaFallbackLogged) {
        this.workAreaFallbackLogged = true;
        Log.w(TAG, `getAvailableArea failed for ${this.viewIdStr}: ` +
          `${JSON.stringify(e)}; constraining against the FULL display instead`);
      }
    }
    out.left = 0;
    out.top = 0;
    out.width = disp.width;
    out.height = disp.height;
  }

  /**
   * Dart positioner round-trip. True = `pos` holds the LOGICAL placement
   * rect (which the constraint adjustment resizeX/resizeY may have
   * SHRUNK); false → keep default OS placement. Protected seam: tests
   * override to simulate positioner results.
   */
  protected computePlacement(pos: WindowPositionResult,
                             logicalW: number, logicalH: number,
                             parentLeft: number, parentTop: number,
                             parentW: number, parentH: number,
                             workLeft: number, workTop: number,
                             workW: number, workH: number): boolean {
    return FlutterNapi.nativeComputeWindowPosition(pos, this.viewId,
      logicalW, logicalH, parentLeft, parentTop, parentW, parentH,
      workLeft, workTop, workW, workH) === 0;
  }

  /**
   * Moves the window to the Dart positioner's LOGICAL position
   * (moveWindowTo takes PHYSICAL px ×dpr). The parent's screen geometry
   * lives only here, hence the nativeComputeWindowPosition round trip.
   * When the positioner shrank the child (resizeX/resizeY), the returned
   * rect carries the reduced size and the window is resized to it before
   * the move — win32's SetWindowPos does the same in one call. The
   * framework learns the new size through the ordinary resize → area
   * change → viewport-metrics path (no win32-style explicit metrics push
   * needed). Fully guarded — never throws (both call sites rely on that).
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
      const wr = parentWin.getWindowProperties().windowRect;
      if (this.parentPhysW === undefined || this.parentPhysH === undefined) {
        this.parentPhysW = Math.round(wr.width);
        this.parentPhysH = Math.round(wr.height);
      }
      let drLeft = 0;
      let drTop = 0;
      let drW = wr.width;
      let drH = wr.height;
      try {
        const dr = parentWin.getWindowProperties().drawableRect;
        drLeft = dr.left; drTop = dr.top; drW = dr.width; drH = dr.height;
      } catch (_) { /* keep windowRect as-is */ }
      const wa = new WorkArea();
      await this.workAreaPhysical(wa, display.getDefaultDisplaySync());
      const pos = new WindowPositionResult();
      // Invoke the positioner with the WINDOW's logical size so the host
      // lands exactly where the positioner says the window belongs.
      const placed = this.computePlacement(pos,
        logicalW, logicalH,
        (wr.left + drLeft) / dpr, (wr.top + drTop) / dpr, // content-origin (logical)
        drW / dpr, drH / dpr, // parent content size (logical)
        wa.left / dpr, wa.top / dpr, wa.width / dpr, wa.height / dpr); // work area (logical)
      if (placed) {
        const px = Math.round(pos.left * dpr);
        const py = Math.round(pos.top * dpr);
        const pw = Math.round(pos.width * dpr);
        const ph = Math.round(pos.height * dpr);
        // Seed the size baseline once from the live window (birth size) so
        // the no-shrink common path never issues a redundant resize.
        if (this.appliedPhysW === undefined || this.appliedPhysH === undefined) {
          try {
            const cur = subWindow.getWindowProperties().windowRect;
            this.appliedPhysW = Math.round(cur.width);
            this.appliedPhysH = Math.round(cur.height);
          } catch (_) { /* size unknown → resize unconditionally below */ }
        }
        if (pw > 0 && ph > 0 &&
            (pw !== this.appliedPhysW || ph !== this.appliedPhysH)) {
          await subWindow.resize(pw, ph);
          this.appliedPhysW = pw;
          this.appliedPhysH = ph;
        }
        await subWindow.moveWindowToAsync(px, py);
      }
    } catch (e) {
      Log.w(TAG, `subWindow position compute/move failed ` +
        `for viewId=${this.viewIdStr}: ${JSON.stringify(e)}`);
    }
  }

  reanchor(): void {
    if (!this.anchored) {
      return;
    }
    const sub = this.subWindow;
    if (!sub) {
      return;
    }
    if (this.preferredLogicalW <= 0 || this.preferredLogicalH <= 0) {
      return;
    }
    if (this.positioning) {
      this.reanchorPending = true;
      return;
    }
    this.reanchorFlight();
  }

  private async reanchorFlight(): Promise<void> {
    this.positioning = true;
    try {
      await this.positionAt(this.preferredLogicalW, this.preferredLogicalH);
    } catch (e) {
      Log.w(TAG, `reanchor failed viewId=${this.viewIdStr}: ${JSON.stringify(e)}`);
    } finally {
      this.positioning = false;
    }
    if (this.reanchorPending) {
      this.reanchorPending = false;
      this.reanchor();
    }
  }
}
