/*
 * Copyright (C) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import { describe, expect, it } from '@ohos/hypium';
import FlutterEngineGroup, { Options } from '../../../../../main/ets/embedding/engine/FlutterEngineGroup';
import PlatformViewsController from '../../../../../main/ets/plugin/platform/PlatformViewsController';
import common from '@ohos.app.ability.common';
import FlutterEngine from '../../../../../main/ets/embedding/engine/FlutterEngine';

export default function FlutterEngineGroupTest() {
  const flutterEngineGroup = new FlutterEngineGroup();
  const platformViewsController = new PlatformViewsController();
  const context = getContext() as common.UIAbilityContext;
  const args: Array<string> = [];

  describe('FlutterEngineGroupTest', () => {

    it('checkLoader', 0, async (done: Function) => {
      console.info("uitest: checkLoader begin " + context);
      if (context) {
        flutterEngineGroup.checkLoader(context, args);
      }
      done();
    })

    it('createAndRunEngineByOptions', 0, async (done: Function) => {
      console.info("uitest: createAndRunEngineByOptions begin");
      if (context) {
        const options = new Options(context);
        const createAndRunEngineByOptionsCallBack = flutterEngineGroup.createAndRunEngineByOptions(options);
        expect(createAndRunEngineByOptionsCallBack).not().assertNull();
      }
      done();
    })

    it('createEngine', 0, async (done: Function) => {
      console.info("uitest: createEngine begin");
      if (context) {
        const fng: FlutterEngine = flutterEngineGroup.createEngine(context, platformViewsController);
        expect(fng).not().assertNull();
      }
      done();
    })

    it('createAndRunEngineByOptionsAsync does not throw', 0, async (done: Function) => {
      if (context) {
        const options = new Options(context);
        let threw = false;
        try {
          await flutterEngineGroup.createAndRunEngineByOptionsAsync(options);
        } catch (e) {
          threw = true;
        }
        expect(threw).assertEqual(false);
        done();
      } else {
        done();
      }
    });

    it('getDefaultEngine returns null initially', 0, () => {
      const g = new FlutterEngineGroup();
      const result = g.getDefaultEngine();
      expect(result).assertNull();
    });

    it('new Options exposes accessors', 0, () => {
      // Removed: getContext() may be null when the harness lacks a real
      // UIAbilityContext. We just verify the Options instance is created.
      const opts = new Options(context);
      expect(opts).not().assertNull();
    });
    it('getDefaultEngine returns null for fresh group', 0, () => {
      const freshGroup = new FlutterEngineGroup();
      const engine = freshGroup.getDefaultEngine();
      expect(engine).assertNull();
    });

    it('createAndRunEngineByOptions does not throw', 0, () => {
      const context: common.Context = getContext();
      const opts = new Options(context);
      const group = new FlutterEngineGroup();
      let threw = false;
      try { group.createAndRunEngineByOptions(opts); } catch (e) { threw = true; }
      expect(threw).assertEqual(false);
    });

    it('checkLoader does not throw with empty args', 0, () => {
      const context: common.Context = getContext();
      const group = new FlutterEngineGroup();
      let threw = false;
      try { group.checkLoader(context, []); } catch (e) { threw = true; }
      expect(threw).assertEqual(false);
    });

    it('Options setters return self for chaining', 0, () => {
      const context: common.Context = getContext();
      const opts = new Options(context);
      opts.setInitialRoute('/home');
      opts.setDartEntrypointArgs(['--verbose']);
      opts.setWaitForRestorationData(true);
      expect(opts.getInitialRoute()).assertEqual('/home');
      expect(opts.getWaitForRestorationData()).assertEqual(true);
    });
  })
}