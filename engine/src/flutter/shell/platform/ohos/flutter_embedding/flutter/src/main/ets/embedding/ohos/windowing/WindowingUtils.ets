/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import window from '@ohos.window';
import Log from '../../../util/Log';

const TAG = 'WindowingUtils';

/**
 * Shared helpers for the windowing hosts — the extension point for
 * cross-host utilities: add future helpers here instead of new files.
 */

/**
 * Resizes |win| so its CONTENT area becomes |physW| × |physH| (physical px).
 *
 * OHOS Window.resize() sizes the OUTER frame, but the embedding contract is
 * content size (the win32 GetWindowSizeForClientSize analogue), so the frame
 * decoration (windowRect − drawableRect, e.g. the 2in1 title bar) is measured
 * once and added on top. When the outer frame is already at the target the
 * resize is skipped; a failed properties read degrades to a plain resize.
 */
export function resizeWindowToContent(win: window.Window,
                                      physW: number,
                                      physH: number,
                                      where: string,
                                      propagateFailure: boolean = false): Promise<void> {
  let decorW = 0;
  let decorH = 0;
  let outerW = -1;
  let outerH = -1;
  try {
    const props = win.getWindowProperties();
    const outer = props.windowRect;
    const drawable = props.drawableRect;
    if (drawable.width > 0 && drawable.height > 0) {
      decorW = Math.max(0, Math.round(outer.width - drawable.width));
      decorH = Math.max(0, Math.round(outer.height - drawable.height));
      outerW = Math.round(outer.width);
      outerH = Math.round(outer.height);
    }
  } catch (e) {
    Log.w(TAG, `${where}: getWindowProperties failed: ${JSON.stringify(e)}`);
  }
  const targetW = physW + decorW;
  const targetH = physH + decorH;
  if (outerW === targetW && outerH === targetH) {
    return Promise.resolve();
  }
  return win.resize(targetW, targetH).catch((e: Object): Promise<void> => {
    Log.e(TAG, `${where} failed: ${JSON.stringify(e)}`);
    if (propagateFailure) {
      return Promise.reject(e);
    }
    return Promise.resolve();
  });
}
