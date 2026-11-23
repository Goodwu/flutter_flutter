// Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_HW file.

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/src/rendering/auto_fit_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rendering_tester.dart';

void main() {
  TestRenderingFlutterBinding.ensureInitialized();

  setUp(() {
    // Clear any residual errors from previous tests so they don't cascade.
    TestRenderingFlutterBinding.instance.takeAllFlutterErrorDetails().toList();
  });

  /// Helper: creates a [RenderFlex] (Column) whose children have a total
  /// height of [childHeight] each, with [childCount] children, inside a
  /// [RenderAutoFitScale].
  ///
  /// Returns the [RenderAutoFitScale] so the caller can inspect [scale] and
  /// [size] after layout.
  ({RenderAutoFitScale autoFit, RenderFlex flex}) buildColumnWithFixedChildren({
    required int childCount,
    required double childHeight,
    required double maxHeight,
    double minWidth = 0.0,
    double maxWidth = double.infinity,
    double minScaleFactor = 0.85,
  }) {
    final children = <RenderBox>[
      for (int i = 0; i < childCount; i++)
        RenderConstrainedBox(additionalConstraints: BoxConstraints.tightFor(height: childHeight)),
    ];

    final flex = RenderFlex(
      direction: Axis.vertical,
      textDirection: TextDirection.ltr,
      children: children,
    );

    final autoFit = RenderAutoFitScale(minScaleFactor: minScaleFactor, debugLabel: 'test');
    autoFit.child = flex;

    layout(
      autoFit,
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth, maxHeight: maxHeight),
    );

    return (autoFit: autoFit, flex: flex);
  }

  group('RenderAutoFitScale — no child', () {
    test('size is constraints.smallest when child is null', () {
      final autoFit = RenderAutoFitScale();
      layout(
        autoFit,
        constraints: const BoxConstraints(
          minWidth: 100.0,
          maxWidth: 200.0,
          minHeight: 50.0,
          maxHeight: 150.0,
        ),
      );
      expect(autoFit.size, equals(const Size(100.0, 50.0)));
      expect(autoFit.scale, equals(1.0));
    });
  });

  group('RenderAutoFitScale — no overflow', () {
    test('scale is 1.0 when child fits within maxHeight', () {
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 2,
        childHeight: 100.0,
        maxHeight: 300.0,
      );
      expect(result.autoFit.scale, equals(1.0));
      expect(result.autoFit.size.height, equals(300.0));
      expect(result.flex.hasOverflow, isFalse);
    });

    test('scale is 1.0 when child height exactly equals maxHeight', () {
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 3,
        childHeight: 100.0,
        maxHeight: 300.0,
      );
      expect(result.autoFit.scale, equals(1.0));
      expect(result.flex.hasOverflow, isFalse);
    });

    test('computeDryLayout returns child size when maxHeight is infinite', () {
      // The layout() helper caps maxHeight at the renderView height (600),
      // so we test the infinite-maxHeight path via dry layout instead.
      final child = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints.tightFor(height: 500.0),
      );
      final autoFit = RenderAutoFitScale();
      autoFit.child = child;

      final Size drySize = autoFit.getDryLayout(const BoxConstraints(maxWidth: 300.0));
      // When maxHeight is infinite, performLayout sets size = child.size.
      // computeDryLayout mirrors this by returning child.getDryLayout.
      expect(drySize.height, equals(500.0));
    });
  });

  group('RenderAutoFitScale — overflow detection (debug mode)', () {
    // In debug mode, AutoFitScale detects overflow but does NOT apply scaling
    // (scale stays at 1.0) so that the red/yellow overflow stripes remain
    // visible.
    test('detects overflow but keeps scale at 1.0 in debug mode', () {
      expect(kDebugMode, isTrue);

      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 4,
        childHeight: 100.0,
        maxHeight: 300.0,
      );

      // Child total height = 400, available = 300 → overflow = 100.
      expect(result.flex.hasOverflow, isTrue);
      expect(result.flex.overflow, moreOrLessEquals(100.0));

      // Debug mode: scale stays at 1.0 (no visual scaling).
      expect(result.autoFit.scale, equals(1.0));
      expect(result.autoFit.size.height, equals(300.0));
    });

    test('does not scale when overflow is within precisionErrorTolerance', () {
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 3,
        childHeight: 100.0,
        maxHeight: 300.0 - precisionErrorTolerance / 2,
      );

      // Overflow is below tolerance → treated as no overflow.
      expect(result.autoFit.scale, equals(1.0));
    });
  });

  group('RenderAutoFitScale — minScaleFactor', () {
    test('minScaleFactor property is stored correctly', () {
      // In debug mode the scale is always 1.0, but we can still verify that
      // the minScaleFactor property is stored and triggers relayout.
      final autoFit = RenderAutoFitScale(minScaleFactor: 0.5);
      expect(autoFit.minScaleFactor, equals(0.5));
    });

    test('changing minScaleFactor triggers relayout', () {
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 2,
        childHeight: 100.0,
        maxHeight: 300.0,
      );

      // Change minScaleFactor — should mark needs layout.
      result.autoFit.minScaleFactor = 0.5;
      expect(result.autoFit.minScaleFactor, equals(0.5));

      // Pump a new frame to process the relayout.
      pumpFrame();
    });
  });

  group('RenderAutoFitScale — nested Flex detection', () {
    test('finds root vertical Flex (Column) not horizontal Flex (Row)', () {
      // Build: AutoFitScale → Column → [Row → [fixed child]]
      // The Row is horizontal, so the root vertical Flex should be the Column.
      final leaf = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints.tightFor(height: 400.0),
      );

      final row = RenderFlex(textDirection: TextDirection.ltr, children: <RenderBox>[leaf]);

      final column = RenderFlex(direction: Axis.vertical, children: <RenderBox>[row]);

      final autoFit = RenderAutoFitScale(debugLabel: 'nested');
      autoFit.child = column;

      layout(autoFit, constraints: const BoxConstraints(maxWidth: 300.0, maxHeight: 200.0));

      // Column has overflow (400 > 200).
      expect(column.hasOverflow, isTrue);
      // Debug mode: scale stays at 1.0.
      expect(autoFit.scale, equals(1.0));
    });

    test('detects overflow in a later sibling flex, not just the first one', () {
      // Build: AutoFitScale → Stack → [Column A (fits), Column B (overflows)]
      // The DFS-first-match implementation only looked at Column A and missed
      // Column B's overflow; all root-level vertical flexes must be checked.
      final logs = <String>[];
      final DebugPrintCallback originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
      addTearDown(() {
        debugPrint = originalPrint;
      });

      final columnA = RenderFlex(
        direction: Axis.vertical,
        textDirection: TextDirection.ltr,
        children: <RenderBox>[
          RenderConstrainedBox(additionalConstraints: const BoxConstraints.tightFor(height: 100.0)),
        ],
      );

      final columnB = RenderFlex(
        direction: Axis.vertical,
        textDirection: TextDirection.ltr,
        children: <RenderBox>[
          RenderConstrainedBox(additionalConstraints: const BoxConstraints.tightFor(height: 300.0)),
        ],
      );

      final stack = RenderStack(
        textDirection: TextDirection.ltr,
        children: <RenderBox>[columnA, columnB],
      );

      final autoFit = RenderAutoFitScale(debugLabel: 'siblings');
      autoFit.child = stack;

      layout(autoFit, constraints: const BoxConstraints(maxWidth: 300.0, maxHeight: 200.0));

      expect(columnA.hasOverflow, isFalse);
      expect(columnB.hasOverflow, isTrue);

      // Overflow was detected from the later sibling flex: maxHeight=200,
      // natural=200+100=300 → scale would be 200/300 ≈ 0.67, clamped to
      // minScaleFactor 0.85.
      expect(logs, hasLength(1));
      expect(logs.single, contains('overflow 100.0px'));
      expect(logs.single, contains('scale=0.85'));
      // Debug mode: scale stays at 1.0.
      expect(autoFit.scale, equals(1.0));
    });

    test('uses the largest overflow among sibling flexes', () {
      // Build: AutoFitScale → Stack → [Column A (overflows by 100),
      // Column B (overflows by 200)] → the max overflow drives the scale.
      final logs = <String>[];
      final DebugPrintCallback originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };

      addTearDown(() {
        debugPrint = originalPrint;
      });

      final columnA = RenderFlex(
        direction: Axis.vertical,
        textDirection: TextDirection.ltr,
        children: <RenderBox>[
          RenderConstrainedBox(additionalConstraints: const BoxConstraints.tightFor(height: 300.0)),
        ],
      );

      final columnB = RenderFlex(
        direction: Axis.vertical,
        textDirection: TextDirection.ltr,
        children: <RenderBox>[
          RenderConstrainedBox(additionalConstraints: const BoxConstraints.tightFor(height: 400.0)),
        ],
      );

      final stack = RenderStack(
        textDirection: TextDirection.ltr,
        children: <RenderBox>[columnA, columnB],
      );

      final autoFit = RenderAutoFitScale(debugLabel: 'max-overflow');
      autoFit.child = stack;

      layout(autoFit, constraints: const BoxConstraints(maxWidth: 300.0, maxHeight: 200.0));

      expect(columnA.overflow, moreOrLessEquals(100.0));
      expect(columnB.overflow, moreOrLessEquals(200.0));

      // The max overflow (200) is used: scale = 200 / (200 + 200) = 0.5,
      // clamped to minScaleFactor 0.85.
      expect(logs.single, contains('overflow 200.0px'));
      expect(logs.single, contains('scale=0.85'));
    });

    test('does not detect overflow when child is not a Flex', () {
      final child = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints.tightFor(height: 500.0),
      );

      final autoFit = RenderAutoFitScale();
      autoFit.child = child;

      layout(autoFit, constraints: const BoxConstraints(maxWidth: 300.0, maxHeight: 200.0));

      // No RenderFlex in the subtree → no overflow detection → scale = 1.0.
      expect(autoFit.scale, equals(1.0));
      // The child is taller than maxHeight, but since it's not a Flex,
      // AutoFitScale doesn't detect overflow.
      expect(autoFit.size.height, equals(200.0));
    });
  });

  group('RenderAutoFitScale — intrinsic height', () {
    test('computeMinIntrinsicHeight returns child intrinsic height', () {
      final child = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints.tightFor(height: 150.0),
      );
      final autoFit = RenderAutoFitScale();
      autoFit.child = child;

      expect(autoFit.getMinIntrinsicHeight(100.0), equals(150.0));
    });

    test('computeMaxIntrinsicHeight returns child intrinsic height', () {
      final child = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints.tightFor(height: 250.0),
      );
      final autoFit = RenderAutoFitScale();
      autoFit.child = child;

      expect(autoFit.getMaxIntrinsicHeight(100.0), equals(250.0));
    });

    test('intrinsic height is 0 when child is null', () {
      final autoFit = RenderAutoFitScale();
      expect(autoFit.getMinIntrinsicHeight(100.0), equals(0.0));
      expect(autoFit.getMaxIntrinsicHeight(100.0), equals(0.0));
    });
  });

  group('RenderAutoFitScale — dry layout', () {
    test('computeDryLayout returns available area when maxHeight is finite', () {
      final child = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints.tightFor(width: 100.0, height: 200.0),
      );
      final autoFit = RenderAutoFitScale();
      autoFit.child = child;

      final Size drySize = autoFit.getDryLayout(
        const BoxConstraints(maxWidth: 300.0, maxHeight: 400.0),
      );
      // performLayout sets size = constrainDimensions(maxWidth, maxHeight).
      // computeDryLayout must return the same.
      expect(drySize, equals(const Size(300.0, 400.0)));
    });

    test('computeDryLayout returns constraints.smallest when child is null', () {
      final autoFit = RenderAutoFitScale();
      final Size drySize = autoFit.getDryLayout(
        const BoxConstraints(minWidth: 50.0, maxWidth: 200.0, minHeight: 50.0, maxHeight: 200.0),
      );
      expect(drySize, equals(const Size(50.0, 50.0)));
    });
  });

  group('RenderAutoFitScale — debugFillProperties', () {
    test('includes minScaleFactor and scale in diagnostics', () {
      final autoFit = RenderAutoFitScale(minScaleFactor: 0.7, debugLabel: 'my-page');

      final builder = DiagnosticPropertiesBuilder();
      autoFit.debugFillProperties(builder);

      final List<String> properties = builder.properties
          .map((DiagnosticsNode node) => node.toString())
          .toList();

      expect(properties, anyElement(contains('minScaleFactor')));
      expect(properties, anyElement(contains('0.7')));
    });
  });

  group('RenderAutoFitScale — paint and hit test', () {
    test('paint applies no transform when scale is 1.0', () {
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 2,
        childHeight: 100.0,
        maxHeight: 300.0,
      );

      // No overflow → scale = 1.0 → no transform layer.
      expect(result.autoFit.scale, equals(1.0));
      // ignore: invalid_use_of_protected_member
      expect(result.autoFit.layer, isNull);
    });

    test('hitTestChildren returns false when size is empty', () {
      final child = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints.tightFor(height: 100.0),
      );
      final autoFit = RenderAutoFitScale();
      autoFit.child = child;

      // Layout with zero-size constraints.
      layout(autoFit, constraints: const BoxConstraints.tightFor(width: 0.0, height: 0.0));

      final result = BoxHitTestResult();
      expect(autoFit.hitTestChildren(result, position: Offset.zero), isFalse);
    });
  });

  group('RenderAutoFitScale — release scaling path (debugScaleOverride)', () {
    // `flutter test` runs in debug mode; debugScaleOverride lets these tests
    // exercise the release-only two-stage layout + paint scaling path,
    // mirroring the old strategy's debugDynamicDpiEnabled testing hook.
    setUp(() {
      RenderAutoFitScale.debugScaleOverride = true;
    });
    tearDown(() {
      RenderAutoFitScale.debugScaleOverride = null;
    });

    test('applies clamped scale on overflow', () {
      // 4 children × 100px = 400 total, maxHeight = 300 → overflow 100.
      // scale = 300 / (300 + 100) = 0.75, which is below minScaleFactor 0.85
      // → clamped to 0.85.
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 4,
        childHeight: 100.0,
        maxHeight: 300.0,
      );

      expect(result.autoFit.scale, equals(0.85));

      // Even with the enlarged constraints the child still needs more than
      // the 300/0.85 ≈ 352.9px available (children total 400), so the child
      // keeps its overflow — the clamp is a lower bound on scale by design.
      // The render object keeps the available area as its own size.
      expect(result.autoFit.size.height, equals(300.0));
    });

    test('re-lays out the child with enlarged constraints to clear overflow', () {
      // With minScaleFactor 0.5 the scale is unclamped: 300 / 400 = 0.75,
      // and the enlarged constraints (300 / 0.75 = 400) fit the children
      // exactly, clearing the child's overflow.
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 4,
        childHeight: 100.0,
        maxHeight: 300.0,
        minScaleFactor: 0.5,
      );

      expect(result.autoFit.scale, equals(0.75));
      expect(result.flex.hasOverflow, isFalse);
      expect(result.flex.size.height, moreOrLessEquals(400.0));
    });

    test('applies unclamped scale when overflow is small', () {
      // 4 children × 100px = 400 total, maxHeight = 360 → overflow 40.
      // scale = 360 / 400 = 0.9, above minScaleFactor 0.85 → not clamped.
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 4,
        childHeight: 100.0,
        maxHeight: 360.0,
        minScaleFactor: 0.5,
      );

      expect(result.autoFit.scale, equals(0.9));
      expect(result.flex.hasOverflow, isFalse);
      expect(result.flex.size.height, moreOrLessEquals(400.0));
    });

    test('paint applies a transform layer when scaled', () {
      // A RepaintBoundary child forces needsCompositing to be true, which
      // makes pushTransform create a TransformLayer instead of applying a
      // plain canvas transform.
      final leaf = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints.tightFor(width: 50.0, height: 400.0),
      );
      final boundary = RenderRepaintBoundary(child: leaf);
      final column = RenderFlex(
        direction: Axis.vertical,
        textDirection: TextDirection.ltr,
        children: <RenderBox>[boundary],
      );
      final autoFit = RenderAutoFitScale(minScaleFactor: 0.5, debugLabel: 'transform');
      autoFit.child = column;

      layout(autoFit, constraints: const BoxConstraints(maxWidth: 300.0, maxHeight: 300.0));
      expect(autoFit.scale, equals(0.75));

      // Force a repaint to run so the transform layer is pushed.
      // ignore: invalid_use_of_protected_member
      autoFit.markNeedsPaint();
      pumpFrame(phase: EnginePhase.paint);

      // ignore: invalid_use_of_protected_member
      expect(autoFit.layer, isA<TransformLayer>());
    });

    test('keeps scale at 1.0 and no transform layer without overflow', () {
      final ({RenderAutoFitScale autoFit, RenderFlex flex}) result = buildColumnWithFixedChildren(
        childCount: 2,
        childHeight: 100.0,
        maxHeight: 300.0,
      );

      expect(result.autoFit.scale, equals(1.0));
      expect(result.flex.hasOverflow, isFalse);

      pumpFrame(phase: EnginePhase.paint);

      // ignore: invalid_use_of_protected_member
      expect(result.autoFit.layer, isNull);
    });
  });
}
