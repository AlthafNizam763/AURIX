import 'package:aurix/core/config/brand_assets.dart';
import 'package:aurix/shared/widgets/brand/aurix_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  tearDown(BrandAssets.debugReset);

  group('AurixLogo', () {
    testWidgets('draws the mark when no custom asset is bundled', (tester) async {
      BrandAssets.debugSetHasCustomLogo(false);

      await tester.pumpWidget(wrapForTest(const AurixLogo(size: 96)));

      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('uses the bundled asset when one is present', (tester) async {
      BrandAssets.debugSetHasCustomLogo(true);

      await tester.pumpWidget(wrapForTest(const AurixLogo(size: 96)));

      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as AssetImage).assetName, BrandAssets.logoPath);
      expect(image.fit, BoxFit.contain);
    });

    testWidgets('falls back to the mark if the asset will not decode',
        (tester) async {
      // The startup probe only proves the bytes exist. A corrupt file must
      // degrade to the drawn mark rather than a broken-image glyph on the
      // splash screen.
      //
      // The fallback is driven directly rather than by hoping the asset fails
      // to decode: this repo *does* bundle a branding image, so waiting for a
      // decode failure tested the bundle's contents instead of the widget.
      BrandAssets.debugSetHasCustomLogo(true);

      await tester.pumpWidget(wrapForTest(const AurixLogo(size: 96)));

      final image = tester.widget<Image>(find.byType(Image));
      final errorBuilder = image.errorBuilder;
      expect(
        errorBuilder,
        isNotNull,
        reason: 'a corrupt bundled logo must have somewhere to degrade to',
      );

      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) =>
                errorBuilder!(context, Exception('corrupt'), StackTrace.empty),
          ),
        ),
      );

      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the wordmark in caps beside the mark', (tester) async {
      BrandAssets.debugSetHasCustomLogo(false);

      await tester.pumpWidget(
        wrapForTest(const AurixLogo(size: 64, showWordmark: true)),
      );

      expect(find.text('AURIX'), findsOneWidget);
    });

    testWidgets('omits the wordmark by default', (tester) async {
      BrandAssets.debugSetHasCustomLogo(false);

      await tester.pumpWidget(wrapForTest(const AurixLogo(size: 64)));

      expect(find.text('AURIX'), findsNothing);
    });

    testWidgets('lays out at every size it is used at', (tester) async {
      BrandAssets.debugSetHasCustomLogo(false);

      // 16 is the notification-icon case; 116 is the splash badge.
      for (final size in <double>[16, 24, 48, 64, 96, 116, 256]) {
        await tester.pumpWidget(wrapForTest(AurixLogo(size: size)));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'size $size');
      }
    });

    testWidgets('an explicit colour overrides the theme ink', (tester) async {
      // Used where the mark sits on a filled surface and has to invert. There
      // is no `monochrome` flag any more — the whole identity is monochrome, so
      // the only question left is *which* end of the ramp.
      BrandAssets.debugSetHasCustomLogo(false);

      await tester.pumpWidget(
        wrapForTest(const AurixLogo(size: 48, color: Color(0xFF00FF00))),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('the wordmark is tracked, not spaced', (tester) async {
      // The rendering is "A U R I X" but the string must stay "AURIX", or a
      // screen reader spells the brand out letter by letter and text search
      // stops matching it.
      BrandAssets.debugSetHasCustomLogo(false);

      await tester.pumpWidget(wrapForTest(const AurixWordmark(fontSize: 20)));

      final text = tester.widget<Text>(find.byType(Text));
      expect(text.data, 'AURIX');
      expect(text.style?.letterSpacing, greaterThan(4));
    });
  });

  group('AurixLogoBadge', () {
    testWidgets('renders and contains the mark', (tester) async {
      BrandAssets.debugSetHasCustomLogo(false);

      await tester.pumpWidget(wrapForTest(const AurixLogoBadge(size: 108)));

      expect(find.byType(AurixLogo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('BrandAssets', () {
    test('reports no custom logo before the probe has run', () {
      BrandAssets.debugReset();
      expect(BrandAssets.isProbed, isFalse);
      expect(BrandAssets.hasCustomLogo, isFalse);
    });

    test('detect() is safe to call twice', () async {
      BrandAssets.debugReset();
      await BrandAssets.detect();
      await BrandAssets.detect();
      expect(BrandAssets.isProbed, isTrue);
    });

    test('the probe agrees with what the bundle actually carries', () async {
      // Asserted against the manifest rather than against a hard-coded `false`.
      // The old version encoded "this project ships no branding artwork",
      // which stopped being true the moment one was added — and then failed in
      // a way that looked like a bug in the detector rather than a stale
      // assumption in the test.
      BrandAssets.debugReset();
      await BrandAssets.detect();

      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final bundled = manifest.listAssets().contains(BrandAssets.logoPath);

      expect(BrandAssets.isProbed, isTrue);
      expect(
        BrandAssets.hasCustomLogo,
        bundled,
        reason: bundled
            ? '${BrandAssets.logoPath} is bundled, so it should be used'
            : 'nothing is bundled, so the drawn mark should be used',
      );
    });
  });
}
