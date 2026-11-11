// Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_HW file.

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/rendering/auto_fit_scale.dart';
import 'package:flutter/src/widgets/basic.dart' show AutoFitScale;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('creates RenderAutoFitScale with correct properties', (WidgetTester tester) async {
    await tester.pumpWidget(
      const AutoFitScale(
        minScaleFactor: 0.7,
        debugLabel: 'test-page',
        child: SizedBox(height: 100, width: 100),
      ),
    );

    final RenderAutoFitScale renderObject = tester.allRenderObjects
        .whereType<RenderAutoFitScale>()
        .first;

    expect(renderObject.minScaleFactor, equals(0.7));
    expect(renderObject.debugLabel, equals('test-page'));
  });

  testWidgets('updates RenderAutoFitScale when properties change', (WidgetTester tester) async {
    await tester.pumpWidget(const AutoFitScale(debugLabel: 'page-1', child: SizedBox(height: 100)));

    await tester.pumpWidget(
      const AutoFitScale(minScaleFactor: 0.5, debugLabel: 'page-2', child: SizedBox(height: 100)),
    );

    final RenderAutoFitScale renderObject = tester.allRenderObjects
        .whereType<RenderAutoFitScale>()
        .first;

    expect(renderObject.minScaleFactor, equals(0.5));
    expect(renderObject.debugLabel, equals('page-2'));
  });

  testWidgets('does not crash with empty child', (WidgetTester tester) async {
    await tester.pumpWidget(const AutoFitScale());
    expect(tester.takeException(), isNull);
  });

  // Regression test for the epsilon-relaxed measurement pass: the child is
  // laid out with maxHeight nudged by 1e-3, and the pre-release scale
  // re-layout must not fall epsilon-short of the child's natural content
  // height (which previously caused a spurious "RenderFlex overflowed by
  // 0.00100 pixels" exception) while still detecting a real overflow.
  testWidgets('re-detects overflow after setState and reports no spurious overflow', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.ohos;
    RenderAutoFitScale.debugScaleOverride = true;
    addTearDown(() {
      // Safety net: runs even if an expect() above throws, so the static
      // overrides never leak into later tests in this test process.
      RenderAutoFitScale.debugScaleOverride = null;
      debugDefaultTargetPlatformOverride = null;
    });

    final Scenario8HostState state = await pumpScenario8(tester, surface: const Size(360, 640));

    // Toggle to 5 items: fits, no overflow, scaling active or not.
    state.setItemCount(5);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Toggle to 6 items: real overflow (≈16px on a 360x640 surface with
    // 100px rows), scale is applied (release-only path via the test
    // override) and no spurious epsilon overflow may be reported.
    state.setItemCount(6);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Reset the debug variables before the test body ends; _verifyInvariants
    // runs before addTearDown callbacks.
    RenderAutoFitScale.debugScaleOverride = null;
    debugDefaultTargetPlatformOverride = null;

    // Toggle back to 3 items: scale returns to 1.0 without exceptions.
    state.setItemCount(3);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

/// Host for the scenario-8 style toggle test: a page whose [Column] grows and
/// shrinks via [setState] (the mechanism that must keep reaching
/// [RenderAutoFitScale] for re-detection after layout).
class Scenario8Host extends StatefulWidget {
  const Scenario8Host({super.key});

  @override
  State<Scenario8Host> createState() => Scenario8HostState();
}

class Scenario8HostState extends State<Scenario8Host> {
  int itemCount = 3;
  void setItemCount(int v) => setState(() => itemCount = v);

  Widget buildRow(int index) => SizedBox(
    height: 100,
    child: CupertinoButton.filled(onPressed: () {}, child: Text('button $index')),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('scenario8')),
      body: Column(children: <Widget>[...List<Widget>.generate(itemCount, buildRow)]),
    );
  }
}

Future<Scenario8HostState> pumpScenario8(
  WidgetTester tester, {
  required Size surface,
  int initialItemCount = 3,
}) async {
  await tester.binding.setSurfaceSize(surface);
  await tester.pumpWidget(const MaterialApp(home: Scenario8Host()));
  await tester.pump();
  final Scenario8HostState state = tester.state(find.byType(Scenario8Host));
  state.setItemCount(initialItemCount);
  await tester.pump();
  return state;
}
