/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { describe, expect, it, Level } from '@ohos/hypium';
import window from '@ohos.window';
import UIAbility from '@ohos.app.ability.UIAbility';
import { WindowHostRegistry } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowHostRegistry';
import { FlutterWindowHost } from
  '../../../../../../main/ets/embedding/ohos/windowing/FlutterWindowHost';
import { SubWindowHost } from
  '../../../../../../main/ets/embedding/ohos/windowing/SubWindowHost';
import { WindowArchetype } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowArchetype';
import { WindowHostContext } from
  '../../../../../../main/ets/embedding/ohos/windowing/WindowHostContext';
import { FakeHostContext, FakeWindow } from './Fakes';

/** Minimal concrete FlutterWindowHost for registry membership tests. */
class TestBaseHost extends FlutterWindowHost {
  constructor(ctx: WindowHostContext, viewId: number) {
    super(ctx, viewId, 0, WindowArchetype.REGULAR, 0, 0);
  }

  attach(): void {
  }

  resolveWindow(): window.Window | null {
    return null;
  }

  protected closeHost(): void {
  }

  protected closeHostForCascade(parentAbility: UIAbility): void {
  }
}

export default function windowHostRegistryTest() {
  const ctx: FakeHostContext = new FakeHostContext();

  describe('WindowHostRegistry.registerGetUnregister', () => {
    it('register then get returns the host', Level.LEVEL0, () => {
      const registry: WindowHostRegistry = new WindowHostRegistry();
      const host: TestBaseHost = new TestBaseHost(ctx, 1);
      registry.register(host);
      expect(registry.get('1')).assertEqual(host);
    });

    it('get returns undefined for an unknown viewId', Level.LEVEL0, () => {
      const registry: WindowHostRegistry = new WindowHostRegistry();
      expect(registry.get('nope')).assertEqual(undefined);
    });

    it('unregister removes the host', Level.LEVEL0, () => {
      const registry: WindowHostRegistry = new WindowHostRegistry();
      const host: TestBaseHost = new TestBaseHost(ctx, 2);
      registry.register(host);
      registry.unregister('2');
      expect(registry.get('2')).assertEqual(undefined);
    });
  });

  describe('WindowHostRegistry.snapshot', () => {
    it('snapshot lists every live host', Level.LEVEL0, () => {
      const registry: WindowHostRegistry = new WindowHostRegistry();
      const hostA: TestBaseHost = new TestBaseHost(ctx, 3);
      const hostB: TestBaseHost = new TestBaseHost(ctx, 4);
      registry.register(hostA);
      registry.register(hostB);
      const all = registry.snapshot();
      expect(all.length).assertEqual(2);
      expect(all.includes(hostA)).assertTrue();
      expect(all.includes(hostB)).assertTrue();
    });

    it('snapshot is a copy; later unregister does not affect it', Level.LEVEL0, () => {
      const registry: WindowHostRegistry = new WindowHostRegistry();
      const host: TestBaseHost = new TestBaseHost(ctx, 5);
      registry.register(host);
      const all = registry.snapshot();
      registry.unregister('5');
      expect(all.length).assertEqual(1);
    });
  });

  describe('WindowHostRegistry.subWindowOf', () => {
    it('returns the materialized sub-window of a SubWindowHost', Level.LEVEL0, () => {
      const registry: WindowHostRegistry = new WindowHostRegistry();
      const subHost: SubWindowHost = new SubWindowHost(ctx, 6, 0, WindowArchetype.TOOLTIP, 100, 80);
      const fakeWin = new FakeWindow();
      subHost.subWindow = fakeWin as ESObject as window.Window;
      registry.register(subHost);
      expect(registry.subWindowOf('6')).assertEqual(subHost.subWindow);
    });

    it('returns undefined when the SubWindowHost has not materialized', Level.LEVEL0, () => {
      const registry: WindowHostRegistry = new WindowHostRegistry();
      const subHost: SubWindowHost = new SubWindowHost(ctx, 7, 0, WindowArchetype.TOOLTIP, 100, 80);
      registry.register(subHost);
      expect(registry.subWindowOf('7')).assertEqual(undefined);
    });

    it('returns undefined for a non-SubWindow host', Level.LEVEL0, () => {
      const registry: WindowHostRegistry = new WindowHostRegistry();
      const base: TestBaseHost = new TestBaseHost(ctx, 8);
      registry.register(base);
      expect(registry.subWindowOf('8')).assertEqual(undefined);
    });
  });
}
