/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import window from '@ohos.window';
import display from '@ohos.display';
import { BusinessError } from '@ohos.base';
import Log from '../../../util/Log';
import { FlutterView } from '../../../view/FlutterView';
import FlutterNapi, { WindowPositionResult } from '../../engine/FlutterNapi';
import { FlutterWindowHost } from './FlutterWindowHost';
import { WindowHostContext } from './WindowHostContext';
import { BirthPlacement } from './TooltipWindowHost';
import { PopupWindowCreationRequest, WindowArchetype } from './WindowingUtils';

const TAG = 'PopupWindowHost'

const SUB_WINDOW_NAME_PREFIX: string = 'Popup-';

const kPlacementTolerancePx: number = 2;

const kBirthOffscreenPx: number = -10000;

/** A parent-bound, decoration-free, never-focusable SubWindow anchored by
 * the positioner and sized to its content (tooltip parity). */
export class PopupWindowHost extends FlutterWindowHost {
  protected readonly request: PopupWindowCreationRequest;

  private contentWidthPx: number = 0;
  private contentHeightPx: number = 0;

  private positionInFlight: boolean = false;
  private positionPending: boolean = false;

  private surfaceStorage: LocalStorage | null = null;

  private parentWnd: window.Window | null = null;
  private parentWindowEventHandler: ((event: window.WindowEventType) => void) | null = null;
  private parentSizeChangedHandler: ((size: window.Size) => void) | null = null;

  constructor(ctx: WindowHostContext, viewId: number, request: PopupWindowCreationRequest) {
    super(ctx, viewId, request.parentViewId, '', WindowArchetype.POPUP);
    this.request = request;
  }

  async attach(): Promise<void> {
    const parentWnd = this.ctx.getHostWindowByView(this.parentViewId)?.getWindow() ?? undefined;
    if (parentWnd === undefined) {
      Log.e(TAG, `attach: no parent window for parentViewId=${this.parentViewId}`);
      this.failAttach('attach: no parent window');
      return;
    }

    const size = this.getWindowSizeForClientSize(this.initialWindowRect(), undefined, undefined, parentWnd);
    const rect: window.Rect = {
      left: kBirthOffscreenPx, top: kBirthOffscreenPx,
      width: size?.width ?? 0, height: size?.height ?? 0,
    };
    const options: window.SubWindowOptions = {
      title: SUB_WINDOW_NAME_PREFIX + String(this.viewId),
      decorEnabled: false,
      isModal: false,
      maximizeSupported: false,
    };
    if (rect.width > 0 && rect.height > 0) {
      options.windowRect = rect;
    }

    let subWindow: window.Window;
    try {
      subWindow = await parentWnd.createSubWindowWithOptions(SUB_WINDOW_NAME_PREFIX + String(this.viewId), options);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `createSubWindowWithOptions failed for ${String(this.viewId)}: ${JSON.stringify(err)}`);
      this.failAttach('createSubWindowWithOptions');
      return;
    }
    this.window = subWindow;

    if (!this.viewAttachEngine()) {
      return;
    }

    const storage = new LocalStorage();
    storage.setOrCreate('viewId', String(this.viewId));
    this.surfaceStorage = storage;
    try {
      await subWindow.loadContent(this.ctx.subWindowPage(), storage);
      await this.setWindowStyle(subWindow);
      try {
        await subWindow.setWindowFocusable(false);
      } catch (e) {
        Log.w(TAG, `setWindowFocusable(false) failed for ${String(this.viewId)}: ${JSON.stringify(e)}`);
      }
      const showOptions: window.ShowWindowOptions = { focusOnShow: false };
      await subWindow.showWindow(showOptions);
      subWindow.on('windowSizeChange', (size: window.Size) => {
        Log.d(TAG, `windowSizeChange viewId=${String(this.viewId)} ${size.width}x${size.height}px`);
        storage.setOrCreate('windowWidth', size.width);
        storage.setOrCreate('windowHeight', size.height);
      });
      subWindow.on('windowEvent', (event: window.WindowEventType) => {
        if (event === window.WindowEventType.WINDOW_DESTROYED) {
          this.handleOsClosed();
        }
      });
      this.registerParentWndEvent(parentWnd);
    } catch (e) {
      const err = e as BusinessError;
      Log.e(TAG, `loadContent/showWindow failed for ${String(this.viewId)}: ${JSON.stringify(err)}`);
      this.failAttach('loadContent/showWindow');
      return;
    }
  }

  private viewAttachEngine(): boolean {
    const parentView = this.ctx.getHostWindowByView(this.parentViewId)?.getFlutterView() ?? null;
    if (parentView === null) {
      Log.e(TAG, `viewAttachEngine: no parent view ${this.parentViewId} for sub-view ${String(this.viewId)}`);
      this.failAttach('viewAttachEngine: no parent view');
      return false;
    }
    let fv = this.ctx.getFlutterView(String(this.viewId));
    if (fv === null) {
      fv = new FlutterView(String(this.viewId), parentView.getContext());
      this.ctx.registerFlutterView(String(this.viewId), fv);
    }
    if (!fv.isAttachedToFlutterEngine()) {
      const engine = parentView.getFlutterEngine();
      if (engine === null) {
        Log.e(TAG, `viewAttachEngine: parent view ${this.parentViewId} engine unavailable for sub-view ${String(this.viewId)}`);
        this.failAttach('viewAttachEngine: no engine for parent view');
        return false;
      }
      // Keep the engine-wide text input handler across this view's attach.
      const channel = engine.getTextInputChannel();
      const previousHandler = channel !== null ? channel.textInputMethodHandler : null;
      fv.attachToFlutterEngine(engine);
      if (channel !== null) {
        channel.setTextInputMethodHandler(previousHandler);
      }
    }
    return true;
  }

  private initialWindowRect(): window.Size {
    const c = this.request.preferredConstraints;
    const width = c.hasViewConstraints && c.viewMinWidth > 0 ? c.viewMinWidth : 400;
    const height = c.hasViewConstraints && c.viewMinHeight > 0 ? c.viewMinHeight : 200;
    return { width: width, height: height };
  }

  // ---- Placement ------------------------------------------------------------

  protected async computePlacementRect(parentWnd: window.Window,
                                       logical: window.Size): Promise<BirthPlacement> {
    const size = this.getWindowSizeForClientSize(logical, undefined, undefined, parentWnd);
    const fallback: window.Rect = { left: 0, top: 0, width: size?.width ?? 0, height: size?.height ?? 0 };
    try {
      const dpr = this.densityPixels(parentWnd);
      const props = parentWnd.getWindowProperties();
      const frame = props.windowRect;
      const dr = props.drawableRect;
      const wa = await this.workAreaPhysical();
      const parentRect: window.Rect = {
        left: (frame.left + dr.left) / dpr, top: (frame.top + dr.top) / dpr,
        width: dr.width / dpr, height: dr.height / dpr,
      };
      const workArea: window.Rect = {
        left: wa.left / dpr, top: wa.top / dpr,
        width: wa.width / dpr, height: wa.height / dpr,
      };
      const pos = new WindowPositionResult();
      const placed = this.computePlacement(pos, logical, parentRect, workArea);
      if (!placed) {
        return { rect: fallback, placed: false };
      }
      // win32 parity: the positioner rect applies verbatim (no host-side clamp).
      const rect: window.Rect = {
        left: Math.round(pos.left * dpr),
        top: Math.round(pos.top * dpr),
        width: pos.width > 0 ? Math.round(pos.width * dpr) : fallback.width,
        height: pos.height > 0 ? Math.round(pos.height * dpr) : fallback.height,
      };
      return { rect: rect, placed: true };
    } catch (e) {
      Log.w(TAG, `computePlacementRect failed for ${String(this.viewId)}: ${JSON.stringify(e)}`);
      return { rect: fallback, placed: false };
    }
  }

  /** Screen work area in physical px. */
  protected async workAreaPhysical(): Promise<window.Rect> {
    const disp = display.getDefaultDisplaySync();
    try {
      const wa = await disp.getAvailableArea();
      if (wa.width > 0 && wa.height > 0) {
        return wa;
      }
    } catch (e) {
      Log.w(TAG, `getAvailableArea failed: ${JSON.stringify(e)}; ` +
        `constraining against the FULL display instead`);
    }
    return { left: 0, top: 0, width: disp.width, height: disp.height };
  }

  protected computePlacement(pos: WindowPositionResult,
                             childSize: window.Size,
                             parentRect: window.Rect,
                             workArea: window.Rect): boolean {
    return FlutterNapi.nativeComputeWindowPosition(
      pos, this.viewId, childSize, parentRect, workArea) === 0;
  }

  didUpdateViewSize(widthPx: number, heightPx: number): void {
    if (Math.abs(widthPx - this.contentWidthPx) <= kPlacementTolerancePx &&
        Math.abs(heightPx - this.contentHeightPx) <= kPlacementTolerancePx) {
      return;
    }
    this.contentWidthPx = widthPx;
    this.contentHeightPx = heightPx;
    Log.d(TAG, `didUpdateViewSize viewId=${String(this.viewId)} content=${widthPx}x${heightPx}px`);
    // The render surface follows the content size (tooltip parity).
    this.surfaceStorage?.setOrCreate('surfaceWidth', widthPx);
    this.surfaceStorage?.setOrCreate('surfaceHeight', heightPx);
    this.scheduleUpdatePosition();
  }

  private childLogicalSize(parentWnd: window.Window): window.Size {
    if (this.contentWidthPx > 0 && this.contentHeightPx > 0) {
      const dpr = this.densityPixels(parentWnd);
      return {
        width: this.contentWidthPx / dpr,
        height: this.contentHeightPx / dpr,
      };
    }
    return this.initialWindowRect();
  }

  private scheduleUpdatePosition(): void {
    if (this.positionInFlight) {
      this.positionPending = true;
      return;
    }
    this.positionInFlight = true;
    const done = (): void => {
      this.positionInFlight = false;
      if (this.positionPending) {
        this.positionPending = false;
        this.scheduleUpdatePosition();
      }
    };
    this.updatePosition().then(done, done);
  }

  async updatePosition(): Promise<void> {
    const win = this.window;
    const parentWnd =
      this.ctx.getHostWindowByView(this.parentViewId)?.getWindow() ?? undefined;
    if (win === undefined || parentWnd === undefined) {
      return;
    }
    try {
      const placement =
        await this.computePlacementRect(parentWnd, this.childLogicalSize(parentWnd));
      if (!placement.placed) {
        return;
      }
      const r = placement.rect;
      const cur = win.getWindowProperties().windowRect;
      const needsResize = r.width > 0 && r.height > 0 &&
        (Math.abs(cur.width - r.width) > kPlacementTolerancePx ||
         Math.abs(cur.height - r.height) > kPlacementTolerancePx);
      const needsMove = Math.abs(cur.left - r.left) > kPlacementTolerancePx ||
        Math.abs(cur.top - r.top) > kPlacementTolerancePx;
      if (!needsResize && !needsMove) {
        return;
      }
      if (needsMove) {
        await win.moveWindowToAsync(r.left, r.top);
      }
      if (needsResize) {
        try {
          await win.resizeAsync(r.width, r.height);
        } catch (e) {
          Log.w(TAG, `updatePosition: resize rejected (non-FLOATING?) for ` +
            `${String(this.viewId)}: ${JSON.stringify(e)}`);
        }
      }
    } catch (e) {
      Log.w(TAG, `updatePosition failed for ${String(this.viewId)}: ${JSON.stringify(e)}`);
    }
  }

  detachView(): void {
    // Keep the engine-wide text input handler across this view's teardown.
    const fv = this.getFlutterView();
    const channel = fv !== null ? fv.getFlutterEngine()?.getTextInputChannel() ?? null : null;
    const previousHandler = channel !== null ? channel.textInputMethodHandler : null;
    super.detachView();
    if (channel !== null && previousHandler !== null) {
      channel.setTextInputMethodHandler(previousHandler);
    }
  }

  // ---- Parent-driven dismissal ----------------------------------------------

  private registerParentWndEvent(parentWnd: window.Window): void {
    this.parentWnd = parentWnd;
    const onEvent = (event: window.WindowEventType) => {
      if (event === window.WindowEventType.WINDOW_INACTIVE ||
          event === window.WindowEventType.WINDOW_HIDDEN ||
          event === window.WindowEventType.WINDOW_DESTROYED) {
        this.closeFromParentEvent();
      }
    };
    // Ignore drag start/end size-same events; only a real resize dismisses.
    let lastWidth = -1;
    let lastHeight = -1;
    try {
      const rect = parentWnd.getWindowProperties().windowRect;
      lastWidth = rect.width;
      lastHeight = rect.height;
    } catch (e) {
      Log.w(TAG, `registerParentWndEvent: parent rect unavailable for ` +
        `${String(this.viewId)}: ${JSON.stringify(e)}`);
    }
    const onSize = (size: window.Size) => {
      const unchanged = lastWidth >= 0 &&
        Math.abs(lastWidth - size.width) <= kPlacementTolerancePx &&
        Math.abs(lastHeight - size.height) <= kPlacementTolerancePx;
      lastWidth = size.width;
      lastHeight = size.height;
      if (unchanged) {
        return;
      }
      this.closeFromParentEvent();
    };
    this.parentWindowEventHandler = onEvent;
    this.parentSizeChangedHandler = onSize;
    parentWnd.on('windowEvent', onEvent);
    parentWnd.on('windowSizeChange', onSize);
  }

  private closeFromParentEvent(): void {
    this.unregisterParentWndEvent();
    this.handleOsClosed();
    this.closeHost();
  }

  private unregisterParentWndEvent(): void {
    const parentWnd = this.parentWnd;
    this.parentWnd = null;
    if (parentWnd === null) {
      return;
    }
    // parentWnd non-null ⟺ both handlers were registered by registerParentWndEvent.
    try {
      parentWnd.off('windowEvent', this.parentWindowEventHandler!);
      parentWnd.off('windowSizeChange', this.parentSizeChangedHandler!);
    } catch (e) {
      Log.w(TAG, `unregisterParentWndEvent: off() failed for ${String(this.viewId)}: ${JSON.stringify(e)}`);
    }
  }

  protected async setWindowStyle(subWindow: window.Window): Promise<void> {
    try {
      subWindow.setWindowBackgroundColor('#00000000');
      subWindow.setWindowShadowRadius(0);
      await subWindow.setWindowCornerRadius(0);
    } catch (e) {
      Log.w(TAG, `applyStyle failed for ${String(this.viewId)}: ${JSON.stringify(e)}`);
    }
  }

  protected failAttach(where: string): void {
    if (this.window !== undefined) {
      this.detachView();
      this.closeHost();
    }
    super.failAttach(where);
  }

  protected closeHost(): void {
    this.unregisterParentWndEvent();
    if (this.window === undefined) {
      Log.w(TAG, `closeHost: no sub-window for ${String(this.viewId)} (already closed?)`);
      return;
    }
    try {
      this.window.destroyWindow((err: BusinessError) => {
        if (err && err.code) {
          Log.w(TAG, `closeHost: destroyWindow failed for ${String(this.viewId)}: ${JSON.stringify(err)}`);
        }
      });
    } catch (e) {
      Log.w(TAG, `closeHost: destroyWindow threw for ${String(this.viewId)}: ${JSON.stringify(e)}`);
    }
  }
}
