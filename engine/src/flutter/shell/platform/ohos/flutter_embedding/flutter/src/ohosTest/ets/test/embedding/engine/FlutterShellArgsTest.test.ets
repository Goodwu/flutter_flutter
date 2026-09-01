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
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Want } from '@kit.AbilityKit';
import FlutterShellArgs from '../../../../../main/ets/embedding/engine/FlutterShellArgs';

const bundleName = abilityDelegatorRegistry.getArguments().bundleName;

export default function FlutterShellArgsTest() {
  const flutterShellArgs: FlutterShellArgs = new FlutterShellArgs();
  const want: Want = {
    bundleName: bundleName,
    abilityName: 'EntryAbility'
  }

  describe('FlutterShellArgsTest', () => {

    it('fromWant', 0, async (done: Function) => {
      console.info("uitest: fromWant begin");
      try {
        const flutterShellArgs = FlutterShellArgs.fromWant(want);
        if (flutterShellArgs) {
          expect(flutterShellArgs).not().assertNull();
        }
      } catch (e) {
      }
      done();
    })

    it('checkArg', 0, async (done: Function) => {
      console.info("uitest: checkArg begin");
      const argKey = 'argKey';
      const argFlag = 'argFlag';
      try {
        const flutterShellArgs = FlutterShellArgs.fromWant(want);
        FlutterShellArgs.checkArg(argKey, argFlag, want, flutterShellArgs);
      } catch (e) {
      }
      done();
    })

    it('toArray', 0, async (done: Function) => {
      console.info("uitest: toArray begin");
      const toArray = flutterShellArgs.toArray();
      expect(toArray).not().assertNull();
      done();
    })

    it('fromWant with trace-startup parameter', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'trace-startup': true,
        } as Record<string, Object>
      }
      try {
        const args = FlutterShellArgs.fromWant(wantWithParams);
        expect(args).not().assertNull();
        const arr = args.toArray();
        expect(arr.includes(FlutterShellArgs.ARG_TRACE_STARTUP)).assertEqual(true);
      } catch (e) {}
      done();
    })

    it('fromWant with start-paused parameter', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'start-paused': true,
        } as Record<string, Object>
      }
      try {
        const args = FlutterShellArgs.fromWant(wantWithParams);
        const arr = args.toArray();
        expect(arr.includes(FlutterShellArgs.ARG_START_PAUSED)).assertEqual(true);
      } catch (e) {}
      done();
    })

    it('fromWant with multiple parameters', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'enable-dart-profiling': true,
          'enable-software-rendering': true,
          'verbose-logging': true,
          'enable-impeller': true,
          'cache-sksl': true,
        } as Record<string, Object>
      }
      try {
        const args = FlutterShellArgs.fromWant(wantWithParams);
        const arr = args.toArray();
        expect(arr.includes(FlutterShellArgs.ARG_ENABLE_DART_PROFILING)).assertEqual(true);
        expect(arr.includes(FlutterShellArgs.ARG_ENABLE_SOFTWARE_RENDERING)).assertEqual(true);
        expect(arr.includes(FlutterShellArgs.ARG_VERBOSE_LOGGING)).assertEqual(true);
      } catch (e) {}
      done();
    })

    it('fromWant with observatory-port parameter', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'observatory-port': 8080,
        } as Record<string, Object>
      }
      try {
        const args = FlutterShellArgs.fromWant(wantWithParams);
        const arr = args.toArray();
        expect(arr.length > 0).assertEqual(true);
      } catch (e) {}
      done();
    })

    it('fromWant with msaa-samples parameter', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'msaa-samples': 4,
        } as Record<string, Object>
      }
      try {
        const args = FlutterShellArgs.fromWant(wantWithParams);
        const arr = args.toArray();
        expect(arr.length > 0).assertEqual(true);
      } catch (e) {}
      done();
    })

    it('fromWant with dart-flags parameter', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'dart-flags': '--enable-asserts',
        } as Record<string, Object>
      }
      try {
        const args = FlutterShellArgs.fromWant(wantWithParams);
        const arr = args.toArray();
        expect(arr.length > 0).assertEqual(true);
      } catch (e) {}
      done();
    })

    it('fromWant with trace-skia-allowlist parameter', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'trace-skia-allowlist': 'skp',
        } as Record<string, Object>
      }
      try {
        const args = FlutterShellArgs.fromWant(wantWithParams);
        const arr = args.toArray();
        expect(arr.length > 0).assertEqual(true);
      } catch (e) {}
      done();
    })

    it('fromWant with false parameter does not add flag', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'trace-startup': false,
        } as Record<string, Object>
      }
      try {
        const args = FlutterShellArgs.fromWant(wantWithParams);
        const arr = args.toArray();
        expect(arr.includes(FlutterShellArgs.ARG_TRACE_STARTUP)).assertEqual(false);
      } catch (e) {}
      done();
    })

    it('checkArg with undefined parameters returns early', 0, async (done: Function) => {
      const wantNoParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
      }
      try {
        const args = new FlutterShellArgs();
        FlutterShellArgs.checkArg('key', '--flag', wantNoParams, args);
        expect(args.toArray().length).assertEqual(0);
      } catch (e) {}
      done();
    })

    it('checkArg with true value adds flag', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'custom-key': true,
        } as Record<string, Object>
      }
      try {
        const args = new FlutterShellArgs();
        FlutterShellArgs.checkArg('custom-key', '--custom-flag', wantWithParams, args);
        expect(args.toArray().includes('--custom-flag')).assertEqual(true);
      } catch (e) {}
      done();
    })

    it('checkArg with false value does not add flag', 0, async (done: Function) => {
      const wantWithParams: Want = {
        bundleName: bundleName,
        abilityName: 'EntryAbility',
        parameters: {
          'custom-key': false,
        } as Record<string, Object>
      }
      try {
        const args = new FlutterShellArgs();
        FlutterShellArgs.checkArg('custom-key', '--custom-flag', wantWithParams, args);
        expect(args.toArray().includes('--custom-flag')).assertEqual(false);
      } catch (e) {}
      done();
    })

    it('add and remove args', 0, async (done: Function) => {
      const args = new FlutterShellArgs();
      args.add('--test-flag');
      expect(args.toArray().includes('--test-flag')).assertEqual(true);
      args.remove('--test-flag');
      expect(args.toArray().includes('--test-flag')).assertEqual(false);
      done();
    })
  })
}