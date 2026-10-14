/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { describe, expect, it, Level } from '@ohos/hypium';
import { PopupWindowHost } from
  '../../../../../../main/ets/embedding/ohos/windowing/PopupWindowHost';
import { WindowArchetype } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowingUtils';
import { WindowHostContext } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowHostContext';
import { FakeHostContext, popupRequest } from './Fakes';

// The popup host is still a stub (windowing step 4): the prepareShow
// non-focusable assertions, touchOutside close, and destroy no-re-show
// tests return together with the host implementation.
export default function popupWindowHostTest() {
  describe('PopupWindowHost.constructor', () => {
    it('passes the POPUP archetype', Level.LEVEL0, () => {
      const ctx: WindowHostContext = new FakeHostContext();
      const host: PopupWindowHost = new PopupWindowHost(ctx, 1, popupRequest(0));
      expect(host.archetype).assertEqual(WindowArchetype.POPUP);
      expect(host.viewId).assertEqual(1);
      expect(host.parentViewId).assertEqual(0);
    });
  });
}
