// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/ohos/application_package.dart';
import 'package:flutter_tools/src/ohos/ohos_device.dart';
import 'package:flutter_tools/src/ohos/ohos_sdk.dart';
import 'package:test/fake.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_process_manager.dart';

void main() {
  testUsingContext(
    'startApp using route',
    () async {
      final processManager = FakeProcessManager.list(<FakeCommand>[
        // targetPlatform: param get (sync)
        const FakeCommand(
          command: <String>['hdc', '-t', '123', 'shell', 'param', 'get'],
          stdout: 'const.product.cpu.abilist=arm64-v8a',
        ),
        // stopApp: aa detach (async)
        const FakeCommand(
          command: <String>['hdc', '-t', '123', 'shell', 'aa', 'detach', '-b', 'com.example.test'],
        ),
        // stopApp: aa force-stop (sync)
        const FakeCommand(
          command: <String>['hdc', '-t', '123', 'shell', 'aa', 'force-stop', 'com.example.test'],
        ),
        // isAppInstalled: bm dump (sync)
        const FakeCommand(
          command: <String>['hdc', '-t', '123', 'shell', '"bm dump -n com.example.test"'],
          stdout: '/bin/sh: bm dump -n com.example.test: inaccessible or not found',
        ),
        // installApp: rm -rf
        const FakeCommand(
          command: <String>[
            'hdc',
            '-t',
            '123',
            'shell',
            'rm',
            '-rf',
            'data/local/tmp/flutterInstallTemp',
          ],
        ),
        // installApp: mkdir
        const FakeCommand(
          command: <String>[
            'hdc',
            '-t',
            '123',
            'shell',
            'mkdir',
            'data/local/tmp/flutterInstallTemp',
          ],
        ),
        // installApp: file send
        const FakeCommand(
          command: <String>[
            'hdc',
            '-t',
            '123',
            'file',
            'send',
            '/test.hap',
            'data/local/tmp/flutterInstallTemp',
          ],
        ),
        // installApp: bm install
        const FakeCommand(
          command: <String>[
            'hdc',
            '-t',
            '123',
            'shell',
            'bm',
            'install',
            '-p',
            'data/local/tmp/flutterInstallTemp',
          ],
          stdout: 'install bundle successfully.',
        ),
        // installApp: rm -rf cleanup
        const FakeCommand(
          command: <String>[
            'hdc',
            '-t',
            '123',
            'shell',
            'rm',
            '-rf',
            'data/local/tmp/flutterInstallTemp',
          ],
        ),
        // aa start WITH --ps route
        // The --ps route argument below is determined by what is passed into
        // route argument to startApp.
        const FakeCommand(
          command: <String>[
            'hdc',
            '-t',
            '123',
            'shell',
            'aa',
            'start',
            '-a',
            'EntryAbility',
            '-b',
            'com.example.test',
            '--ps',
            'route',
            '/animation',
          ],
          stdout: 'start ability successfully.',
        ),
      ]);

      final device = OhosDevice(
        '123',
        logger: BufferLogger.test(),
        processManager: processManager,
        ohosSdk: _FakeHarmonySdk(),
      );

      final OhosHap hap = _createTestHap();

      final LaunchResult launchResult = await device.startApp(
        hap,
        prebuiltApplication: true,
        debuggingOptions: DebuggingOptions.disabled(BuildInfo.release),
        platformArgs: <String, dynamic>{},
        route: '/animation',
      );

      expect(launchResult.started, true);
      expect(processManager, hasNoRemainingExpectations);
    },
    overrides: <Type, Generator>{
      FileSystem: () => MemoryFileSystem.test(),
      ProcessManager: () => FakeProcessManager.any(),
    },
  );
}

OhosHap _createTestHap() {
  // Use globals.fs so the file exists in the same FileSystem the device uses.
  final File hapFile = globals.fs.file('/test.hap')..createSync();

  final appInfo = AppInfo('com.example.test', 1, '1.0.0');
  final module = OhosModule(
    name: 'entry',
    srcPath: './entry',
    isEntry: true,
    mainElement: 'EntryAbility',
    type: OhosModuleType.entry,
    flavor: '',
  );
  final moduleInfo = ModuleInfo(<OhosModule>[module]);
  final buildData = OhosBuildData(appInfo, moduleInfo, 12, null);

  return OhosHap(id: 'com.example.test', applicationPackage: hapFile, ohosBuildData: buildData);
}

class _FakeHarmonySdk extends Fake implements HarmonySdk {
  @override
  String get name => 'FakeHarmonySDK';

  @override
  String get sdkPath => '/fake/sdk';

  @override
  String? get hdcPath => 'hdc';

  @override
  String? get npmPath => null;

  @override
  List<String> get apiAvailable => const <String>['12'];

  @override
  bool get isValidDirectory => true;
}
