/*
 * Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

import window from '@ohos.window';
import { FlutterWindowHost } from './FlutterWindowHost';
import { SubWindowHost } from './SubWindowHost';

/**
 * viewId → window-host registry, owned by FlutterManager. Membership IS
 * the record that a host exists; the host object carries its own kind.
 */
export class WindowHostRegistry {
  private readonly hosts = new Map<string, FlutterWindowHost>();

  register(host: FlutterWindowHost): void {
    this.hosts.set(host.viewIdStr, host);
  }

  unregister(viewIdStr: string): void {
    this.hosts.delete(viewIdStr);
  }

  get(viewIdStr: string): FlutterWindowHost | undefined {
    return this.hosts.get(viewIdStr);
  }

  decorateTitleButtons(viewIdStr: string): void {
    this.hosts.get(viewIdStr)?.decorateTitleButtons();
  }

  /** Undefined when the view has no SubWindow host or it has not
   * materialized yet. */
  subWindowOf(viewIdStr: string): window.Window | undefined {
    const host = this.hosts.get(viewIdStr);
    if (host instanceof SubWindowHost) {
      return host.subWindow;
    }
    return undefined;
  }

  /** All live hosts (snapshot; safe to mutate the registry while iterating). */
  snapshot(): FlutterWindowHost[] {
    const out: FlutterWindowHost[] = [];
    this.hosts.forEach((host) => {
      out.push(host);
    });
    return out;
  }
}
