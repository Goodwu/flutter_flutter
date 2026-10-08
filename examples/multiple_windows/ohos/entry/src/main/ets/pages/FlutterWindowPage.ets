/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

import { FlutterPage } from '@ohos/flutter_ohos'

// Host page for a non-implicit (sub-window) view: viewId arrives via
// LocalStorage, and FlutterPage's XComponent carries id=viewId so the native
// surface callback routes to NotifyCreateForView.
let storage = LocalStorage.getShared()

@Entry(storage)
@Component
struct FlutterWindowPage {
  @LocalStorageLink('viewId') viewId: string = "";
  // Render-surface size, physical px (tooltip: the CONTENT size).
  @LocalStorageLink('surfaceWidth') surfaceWidth: number = 0;
  @LocalStorageLink('surfaceHeight') surfaceHeight: number = 0;
  // OS-window size; content scales down to fill a clamped window.
  @LocalStorageLink('windowWidth') windowWidth: number = 0;
  @LocalStorageLink('windowHeight') windowHeight: number = 0;

  private fitScale(surface: number, win: number): number {
    if (surface <= 0 || win <= 0 || surface <= win) {
      return 1;
    }
    return win / surface;
  }

  build() {
    Column() {
      // Sized-to-content sub-windows (tooltip/popup) center their content
      // with transparent slack. FlutterPage has no transparency prop (that
      // lives on the internal FlutterSurface, driven by HCPP mode); injecting
      // xComponentColor=Transparent keeps the XComponent see-through after
      // the first frame instead of flipping to the default black.
      FlutterPage({ viewId: this.viewId, xComponentColor: Color.Transparent })
    }
    .width(this.surfaceWidth > 0 ? `${this.surfaceWidth}px` : '100%')
    .height(this.surfaceHeight > 0 ? `${this.surfaceHeight}px` : '100%')
    .scale({
      x: this.fitScale(this.surfaceWidth, this.windowWidth),
      y: this.fitScale(this.surfaceHeight, this.windowHeight),
      centerX: 0,
      centerY: 0,
    })
  }
}
