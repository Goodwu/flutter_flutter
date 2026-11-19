/*
* Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_HW file.
*/

import HiLog from '@ohos.hilog';

const DOMAIN: number = 0x00FF;
const TAG: string = 'Flutter';
const SYMBOL: string = ' --> ';

/**
 * Logger for Flutter DFX boundary records.
 */
export default class DfxLog {
  static i(tag: string, format: string, ...args: Object[]): void {
    if (HiLog.isLoggable(DOMAIN, TAG, HiLog.LogLevel.INFO)) {
      HiLog.info(DOMAIN, TAG, tag + SYMBOL + format, args);
    }
  }
}
