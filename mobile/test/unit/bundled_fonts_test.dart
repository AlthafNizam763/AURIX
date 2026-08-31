import 'dart:io';

import 'package:aurix/core/theme/font_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Keeps `FontRegistry.bundled` honest about what is actually in the build.
///
/// ## Why this is worth a test
///
/// The two halves of "a bundled font" live in different files and neither
/// checks the other. `pubspec.yaml` decides what the engine can resolve;
/// `FontRegistry.bundled` decides what the app *believes* it can resolve
/// without downloading anything. When they disagree the failure is silent in
/// both directions, and silent in the worst way:
///
///  * Listed in `bundled` but missing from `pubspec.yaml` — `resolve` hands the
///    family straight back, `TextStyle` cannot find it, and Flutter falls
///    through to the platform face. No error, no log; the app just renders in
///    the wrong font and looks broken rather than misconfigured.
///  * Declared in `pubspec.yaml` but missing from `bundled` — the family works,
///    but `ensure` treats it as needing an upload and the picker offers it as
///    unavailable.
///
/// This is exactly the drift the comment on `FontRegistry.bundled` warns about,
/// which is a reason to assert it rather than to restate it.
void main() {
  group('bundled fonts', () {
    /// Family names under `flutter: fonts:`, read from the manifest itself.
    ///
    /// Parsed with a regex rather than a YAML package: this is the only YAML
    /// read anywhere in the test suite, and the shape is two fixed keys under a
    /// list. A dependency for that is not worth carrying.
    late final Set<String> declared = () {
      final lines = File('pubspec.yaml').readAsLinesSync();
      final families = <String>{};
      var inFontsBlock = false;

      for (final line in lines) {
        if (RegExp(r'^  fonts:\s*$').hasMatch(line)) {
          inFontsBlock = true;
          continue;
        }
        // Any other top-level or two-space key closes the block.
        if (inFontsBlock && RegExp(r'^ {0,2}\S').hasMatch(line)) break;
        if (!inFontsBlock) continue;

        final match = RegExp(r'^\s*-\s*family:\s*(\S+)\s*$').firstMatch(line);
        if (match != null) families.add(match.group(1)!);
      }
      return families;
    }();

    test('every family the registry calls bundled is declared in pubspec.yaml', () {
      expect(
        FontRegistry.bundled.difference(declared),
        isEmpty,
        reason:
            'These families are treated as always-available but the engine '
            'cannot resolve them, so they render as the platform default.',
      );
    });

    test('every family declared in pubspec.yaml is known to the registry', () {
      expect(
        declared.difference(FontRegistry.bundled),
        isEmpty,
        reason:
            'These families ship in the build but the registry believes they '
            'need an upload, so the picker offers them as unavailable.',
      );
    });

    test('every declared font asset exists on disk', () {
      final assets = File('pubspec.yaml')
          .readAsLinesSync()
          .map(RegExp(r'^\s*-\s*asset:\s*(assets/fonts/\S+)\s*$').firstMatch)
          .nonNulls
          .map((m) => m.group(1)!);

      // A guard against the list and the folder drifting: a missing file is a
      // build-time failure on device but nothing at all in a unit test run.
      expect(assets, isNotEmpty, reason: 'no font assets were parsed');
      for (final asset in assets) {
        expect(File(asset).existsSync(), isTrue, reason: '$asset is missing');
      }
    });

    test('the fallback family is itself bundled', () {
      // The whole defaulting chain rests on this one being resolvable.
      expect(FontRegistry.bundled, contains(FontRegistry.fallbackFamily));
    });
  });
}
