/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { WindowArchetype } from './WindowArchetype';
import { WindowHostContext } from './WindowHostContext';
import { AnchoredWindowHost } from './AnchoredWindowHost';

/** Tooltip host: positioner-anchored, NEVER takes focus (base-class
 * prepareShow). Deactivate and resize policy live in the base class:
 * parent WINDOW_INACTIVE or a parent resize destroys the tooltip
 * immediately — win32 parity (tooltip controller: parent WM_ACTIVATE
 * WA_INACTIVE → destroy, unconditional). */
export class TooltipWindowHost extends AnchoredWindowHost {
  constructor(ctx: WindowHostContext,
              viewId: number,
              parentViewId: number,
              width: number,
              height: number) {
    super(ctx, viewId, parentViewId, WindowArchetype.TOOLTIP, width, height);
  }

  /** Smaller default launch height than popup/dialog hosts. */
  protected defaultLogicalSize(): number[] {
    return [400, 200];
  }
}
