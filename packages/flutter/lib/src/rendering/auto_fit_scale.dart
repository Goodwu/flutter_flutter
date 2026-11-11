// Copyright (c) 2026 Huawei Device Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_HW file.

/// @docImport 'package:flutter/widgets.dart';
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'box.dart';
import 'flex.dart';
import 'layer.dart';
import 'object.dart';
import 'proxy_box.dart';

/// A render object that automatically scales its child to fit the available
/// height.
///
/// See [AutoFitScale] for a detailed description of the two-stage layout +
/// paint mechanism.
///
/// This class is used internally by the Flutter framework to implement
/// automatic page-content scaling on OHOS. It is not exported through
/// `package:flutter/rendering.dart` and is not part of the public API.
@internal
class RenderAutoFitScale extends RenderProxyBox {
  /// Creates a render object that scales its child to fit.
  RenderAutoFitScale({double minScaleFactor = 0.85, this.debugLabel})
    : _minScaleFactor = minScaleFactor;

  /// A label used in debug logs to identify which page this AutoFitScale wraps.
  String? debugLabel;

  /// The minimum scale factor that can be applied.
  double get minScaleFactor => _minScaleFactor;
  double _minScaleFactor;
  set minScaleFactor(double value) {
    if (_minScaleFactor == value) {
      return;
    }
    _minScaleFactor = value;
    markNeedsLayout();
  }

  /// The current scale factor applied to the child.
  ///
  /// 1.0 means no scaling. Values less than 1.0 indicate the child was
  /// scaled down to fit. This is computed during [performLayout] and read
  /// during [paint].
  double get scale => _scale;
  double _scale = 1.0;

  /// The last scale value that was logged via [debugPrint], used to avoid
  /// repeated logging when the scale hasn't changed between layout passes.
  double _lastLoggedScale = 1.0;

  /// Overrides the release-mode check used to decide whether visual scaling
  /// is applied. When null (the default), [kReleaseMode] decides.
  ///
  /// `flutter test` always runs in debug mode, but this flag lets tests
  /// exercise the release-only two-stage layout + paint scaling path
  /// without a release build, mirroring the old dynamic DPI scheme's
  /// `debugDynamicDpiEnabled` testing hook.
  @visibleForTesting
  static bool? debugScaleOverride;

  /// Whether the two-stage scaling path should actually apply. True in
  /// release builds, or in debug mode when overridden by tests.
  bool get _shouldScale => debugScaleOverride ?? kReleaseMode;

  @override
  double computeMinIntrinsicHeight(double width) {
    return child?.getMinIntrinsicHeight(width) ?? 0.0;
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    return child?.getMaxIntrinsicHeight(width) ?? 0.0;
  }

  // Mirrors the constraint relaxation performLayout applies in Step 1, so
  // speculative (dry) baseline computation uses exactly the same constraints
  // as the real layout and the two baselines stay consistent (checked by
  // RenderBox._debugVerifyDryBaselines when debugCheckIntrinsicSizes is on).
  BoxConstraints _relaxedConstraints(covariant BoxConstraints constraints) {
    const relaxEpsilon = 1e-3;
    return constraints.copyWith(minHeight: math.max(0.0, constraints.minHeight - relaxEpsilon));
  }

  @override
  double? computeDryBaseline(covariant BoxConstraints constraints, TextBaseline baseline) {
    final RenderBox? child = this.child;
    if (child == null) {
      return null;
    }
    if (!constraints.maxHeight.isFinite) {
      return child.getDryBaseline(constraints, baseline);
    }
    return child.getDryBaseline(_relaxedConstraints(constraints), baseline);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    if (child == null) {
      return constraints.smallest;
    }
    // performLayout always sets size to the available area (maxWidth ×
    // maxHeight when finite, or the child's size when maxHeight is infinite).
    // Dry layout can't do the two-pass measurement, but it must return the
    // same size that performLayout would produce.
    if (!constraints.maxHeight.isFinite) {
      return child!.getDryLayout(constraints);
    }
    return constraints.constrainDimensions(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _scale = 1.0;
      return;
    }

    final double maxHeight = constraints.maxHeight;

    // If maxHeight is infinite, there is nothing to fit — just lay out the
    // child normally.
    if (!maxHeight.isFinite) {
      child.layout(constraints, parentUsesSize: true);
      _scale = 1.0;
      size = child.size;
      return;
    }

    // Step 1 (measurement pass): Layout with minHeight nudged down by a
    // tiny epsilon so the constraints stay non-tight (minHeight != maxHeight).
    // Non-tight constraints keep the child of this node from becoming its
    // own relayout boundary, so subtree relayout notifications (e.g.
    // setState adding list items) keep reaching this node for re-detection
    // in later frames. maxHeight stays exact so subtrees that size to the
    // available height (e.g. viewports, MainAxisSize.max Columns) get the
    // exact same geometry they would without this node in the tree; the
    // epsilon only surfaces in minHeight, so getHeight-takers (e.g.
    // full-height gesture detectors) shrink by an invisible 0.001px that
    // has no observable effect on geometry or hit-testing. The child
    // height overflow is still observable via RenderFlex.hasOverflow
    // against the exact maxHeight.
    //
    // The epsilon value (1e-3, i.e. 1/1000 px) is chosen to be:
    //  - large enough to survive the double rounding noise of the layout
    //    and scaling arithmetic below (the constraints go through several
    //    multiply/divide round-trips in Step 3; a smaller epsilon could
    //    round away and silently make the constraints tight again);
    //  - small enough to be invisible: at DPR >= 2 one logical pixel is
    //    at least 2 physical pixels, so 0.001 px is roughly three orders
    //    of magnitude below anything the rasterizer can display.
    final BoxConstraints relaxedConstraints = _relaxedConstraints(constraints);
    child.layout(relaxedConstraints, parentUsesSize: true);

    final double? overflowAmount = _findRootVerticalFlexOverflow(child);
    final double naturalHeight = maxHeight + (overflowAmount ?? 0.0);

    // Step 2: No overflow — the child is already laid out with the
    // (nudged) constraints that preserve minHeight semantics, so no
    // additional layout pass is needed.
    if (overflowAmount == null || overflowAmount <= precisionErrorTolerance) {
      _scale = 1.0;
      _lastLoggedScale = 1.0;
      size = constraints.constrainDimensions(constraints.maxWidth, maxHeight);
      return;
    }

    // Compute the scale factor.
    _scale = clampDouble(maxHeight / naturalHeight, _minScaleFactor, 1.0);

    // Log when the computed scale changes (both debug and release), to
    // avoid per-frame spam during animations (e.g. route transitions).
    // The scale is only applied in release mode; in debug the overflow
    // stripes remain visible.
    if (_scale != _lastLoggedScale) {
      debugPrint(
        'AutoFitScale[$debugLabel]: overflow ${overflowAmount.toStringAsFixed(1)}px, '
        'scale=${_scale.toStringAsFixed(2)} (release only)',
      );
      _lastLoggedScale = _scale;
    }

    // In non-release mode (debug/profile, or when not overridden by tests),
    // keep scale at 1.0 so overflow remains visible (red/yellow stripes).
    // The child keeps the layout from Step 1 (minHeight preserved); the
    // widget tree structure is identical between debug and release; only
    // the scaling action differs.
    if (!_shouldScale) {
      _scale = 1.0;
      size = constraints.constrainDimensions(constraints.maxWidth, maxHeight);
      return;
    }

    // Step 3 (release only): Re-layout the child with proportionally larger
    // constraints (both width and height divided by scale), preserving the
    // original minHeight. The larger maxHeight gives internal overflow
    // states (e.g. RenderFlex.hasOverflow) room to clear, and minHeight
    // keeps subtrees that rely on it from collapsing, keeping hit-testing
    // correct. The constraint stays non-tight (maxHeight > minHeight) so
    // this node keeps receiving subtree relayout notifications. The actual
    // visual shrinking happens in paint().
    final double scaledMaxHeight = maxHeight / _scale;
    final double scaledMaxWidth = constraints.maxWidth / _scale;
    child.layout(
      constraints.copyWith(maxHeight: scaledMaxHeight, maxWidth: scaledMaxWidth),
      parentUsesSize: true,
    );

    // The render object's own size is the available area (screen height),
    // not the child's scaled size. The child is visually scaled to fit
    // within this size during paint.
    size = constraints.constrainDimensions(constraints.maxWidth, maxHeight);
  }

  /// Visits every root-level vertical [RenderFlex] (Column) in the subtree
  /// rooted at [node], skipping horizontal Flexes (Rows) and non-Flex
  /// intermediates on the way down.
  ///
  /// A root-level vertical Flex is one with no vertical Flex ancestor within
  /// this subtree. Once a vertical Flex is found, its own subtree is not
  /// descended into: local overflows nested inside it (e.g. within
  /// fixed-height SizedBoxes) are not considered for height-based scaling,
  /// matching the old dynamic DPI scheme's `_isRootVerticalFlex` semantics.
  ///
  /// Unlike a single "first match" search, all sibling root-level vertical
  /// Flexes are visited (e.g. a Stack or Row containing multiple Columns), so
  /// an overflow in any of them is detected.
  void _visitRootVerticalFlexes(RenderObject node, void Function(RenderFlex flex) visitor) {
    if (node is RenderFlex && node.direction == Axis.vertical) {
      visitor(node);
      return;
    }
    node.visitChildren((RenderObject child) => _visitRootVerticalFlexes(child, visitor));
  }

  /// Returns the largest overflow amount among all root-level vertical
  /// [RenderFlex]es that have overflow, or null if none overflows.
  ///
  /// Taking the max (equivalent to the smallest scale factor) matches the
  /// old dynamic DPI scheme's aggregation across all samples.
  double? _findRootVerticalFlexOverflow(RenderObject node) {
    double? maxOverflow;
    _visitRootVerticalFlexes(node, (RenderFlex flex) {
      if (flex.hasOverflow && flex.overflow > (maxOverflow ?? 0.0)) {
        maxOverflow = flex.overflow;
      }
    });
    return maxOverflow;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null || size.isEmpty || child!.size.isEmpty) {
      return;
    }
    if (_scale < 1.0) {
      // Apply a uniform transform to visually shrink the child in both
      // dimensions, preserving aspect ratio.
      layer = context.pushTransform(
        needsCompositing,
        offset,
        Matrix4.diagonal3Values(_scale, _scale, 1.0),
        super.paint,
        oldLayer: layer is TransformLayer ? layer! as TransformLayer : null,
      );
    } else {
      layer = null;
      super.paint(context, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (size.isEmpty || (child?.size.isEmpty ?? false)) {
      return false;
    }
    if (_scale < 1.0) {
      // addWithPaintTransform applies the inverse transform to the hit
      // position internally, so the callback receives the child's local
      // coordinate.
      return result.addWithPaintTransform(
        transform: Matrix4.diagonal3Values(_scale, _scale, 1.0),
        position: position,
        hitTest: (BoxHitTestResult result, Offset position) {
          return super.hitTestChildren(result, position: position);
        },
      );
    }
    return super.hitTestChildren(result, position: position);
  }

  @override
  bool paintsChild(RenderBox child) {
    assert(child.parent == this);
    return !size.isEmpty && !child.size.isEmpty;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (!paintsChild(child)) {
      transform.setZero();
    } else if (_scale < 1.0) {
      transform.multiply(Matrix4.diagonal3Values(_scale, _scale, 1.0));
    }
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('minScaleFactor', _minScaleFactor));
    properties.add(DoubleProperty('scale', _scale));
  }
}
