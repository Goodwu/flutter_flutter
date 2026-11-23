/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import { describe, it, expect, Level } from '@ohos/hypium';
import HiLog from '@ohos.hilog';
import process from '@ohos.process';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import BuildProfile from '../../../../../BuildProfile';
import Log from '../../../../main/ets/util/Log';
import DfxLog from '../../../../main/ets/util/DfxLog';

let logSequence = 0;

async function countInfoLogs(format: string, level: HiLog.LogLevel, dfx: boolean = false): Promise<number> {
  const marker = `DFX_LOG_TEST_${Date.now()}_${logSequence++}`;
  try {
    Log.setLogLevel(level);
    if (dfx) {
      DfxLog.i('DfxLogTest', `${format} marker=${marker}`);
    } else {
      Log.i('DfxLogTest', `${format} marker=${marker}`);
    }
    await new Promise<void>(resolve => setTimeout(resolve, 200));
    const result = await abilityDelegatorRegistry.getAbilityDelegator().executeShellCommand(
      `hilog -x -P ${process.pid} -e ${marker}`, 5);
    expect(result.exitCode).assertEqual(0);
    return result.stdResult.split('\n').filter(line => line.includes('DfxLogTest --> ') &&
      line.includes(marker)).length;
  } finally {
    Log.setLogLevel(HiLog.LogLevel.WARN);
  }
}

export default function logTest() {
  // Ensure all log levels are allowed in this test session so the body of
  // each d/i/w/e/f is entered (instead of being short-circuited by isLoggable).
  Log.setLogLevel(HiLog.LogLevel.DEBUG);

  describe('Log.setLogLevel', () => {
    it('does not throw', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.setLogLevel(HiLog.LogLevel.DEBUG);
        Log.setLogLevel(HiLog.LogLevel.INFO);
        Log.setLogLevel(HiLog.LogLevel.WARN);
        Log.setLogLevel(HiLog.LogLevel.ERROR);
        Log.setLogLevel(HiLog.LogLevel.FATAL);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });
  });

  describe('Log.d', () => {
    it('Log.d does not throw with simple format', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.d('TestTag', 'debug message');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('Log.d does not throw with format and args', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.d('TestTag', 'value is %d', 42);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('Log.d does not throw with empty tag and format', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.d('', '');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });
  });

  describe('DfxLog.i', () => {
    it('DFX logs bypass the local warning threshold', Level.LEVEL1, async () => {
      const expected = HiLog.isLoggable(0x00FF, 'Flutter', HiLog.LogLevel.INFO) ? 1 : 0;
      expect(await countInfoLogs('[FlutterDFX] chain=focus stage=test', HiLog.LogLevel.WARN, true)).assertEqual(expected);
    });

    it('DFX logs follow the active system filter', Level.LEVEL1, async () => {
      const expected = HiLog.isLoggable(0x00FF, 'Flutter', HiLog.LogLevel.INFO) ? 1 : 0;
      expect(await countInfoLogs('[FlutterDFX] chain=focus stage=test', HiLog.LogLevel.DEBUG, true)).assertEqual(expected);
    });

    it('ordinary info logs retain build mode filtering', Level.LEVEL1, async () => {
      const mode = BuildProfile.BUILD_MODE_NAME.toLowerCase();
      const expected = mode !== 'release' && mode !== 'profile' &&
        HiLog.isLoggable(0x00FF, 'Flutter', HiLog.LogLevel.INFO) ? 1 : 0;
      expect(await countInfoLogs('ordinary info message', HiLog.LogLevel.WARN)).assertEqual(expected);
    });

    it('ordinary info logs remain available at the info threshold', Level.LEVEL1, async () => {
      const expected = HiLog.isLoggable(0x00FF, 'Flutter', HiLog.LogLevel.INFO) ? 1 : 0;
      expect(await countInfoLogs('ordinary info message', HiLog.LogLevel.INFO)).assertEqual(expected);
    });

    it('DfxLog.i does not throw with simple format', Level.LEVEL1, () => {
      let threw = false;
      try {
        DfxLog.i('TestTag', '[FlutterDFX] info message');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('DfxLog.i does not throw with format and args', Level.LEVEL1, () => {
      let threw = false;
      try {
        DfxLog.i('TestTag', '[FlutterDFX] value is %s', 'hello');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });
  });

  describe('Log.w', () => {
    it('Log.w does not throw with simple format', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.w('TestTag', 'warn message');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('Log.w does not throw with format and args', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.w('TestTag', 'count is %d', 0);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });
  });

  describe('Log.e', () => {
    it('does not throw with simple format', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.e('TestTag', 'error message');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('does not throw with no args (empty forEach)', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.e('TestTag', 'error without args');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('does not throw with non-Error args (forEach but no Error branch)', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.e('TestTag', 'values: %s %s', 'a', 123);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('does not throw with Error instance (exercises Error branch in forEach)', Level.LEVEL1, () => {
      let threw = false;
      try {
        const err = new Error('boom');
        Log.e('TestTag', 'failed: %s', err);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('does not throw with mixed Error and non-Error args', Level.LEVEL1, () => {
      let threw = false;
      try {
        const err = new Error('boom');
        Log.e('TestTag', 'failed: %s code=%d', err, 500);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });
  });

  describe('Log.f', () => {
    it('Log.f does not throw with simple format', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.f('TestTag', 'fatal message');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });

    it('Log.f does not throw with format and args', Level.LEVEL1, () => {
      let threw = false;
      try {
        Log.f('TestTag', 'fatal value %d', 99);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertEqual(false);
    });
  });
}
