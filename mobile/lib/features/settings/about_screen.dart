import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../shared/widgets/brand/aurix_logo.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';

/// About, including the disclosure of what AURIX is and is not.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _version = '${info.version} (${info.buildNumber})');
    } on Object {
      // Version is decoration on this screen; a failure here should not
      // produce an error state.
      if (mounted) setState(() => _version = '—');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.ground,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const AurixIcon(AurixGlyph.back),
          tooltip: 'Back',
        ),
        title: const Text('About'),
      ),
      body: ContentBounds(
        maxWidth: 620,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            context.pageGutter,
            AppSpacing.xl,
            context.pageGutter,
            AppSpacing.huge,
          ),
          children: [
            const Center(child: AurixLogoBadge(size: 88)),
            const SizedBox(height: AppSpacing.xl),
            const Center(
              child: Text(AppConstants.appName, style: AppTypography.displaySmall),
            ),
            const SizedBox(height: AppSpacing.xs),
            Center(
              child: Text(
                AppConstants.appTagline,
                style: AppTypography.bodyMedium.copyWith(
                  color: context.palette.textTertiary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Center(
              child: Text(
                _version.isEmpty ? '' : 'Version $_version',
                style: AppTypography.labelSmall,
              ),
            ),

            const SizedBox(height: AppSpacing.huge),

            const _Section(
              title: 'What this app is',
              body:
                  'AURIX is an independent client for the official Spotify '
                  'Web API. It shows your Spotify library, catalogue and '
                  'listening history, and controls playback on your own Spotify '
                  'devices. It is not affiliated with, endorsed by, or '
                  'connected to Spotify AB.',
            ),

            const _Section(
              title: 'How playback works',
              body:
                  'AURIX cannot decode Spotify audio — no third-party app '
                  'can. It uses the two mechanisms Spotify authorises:\n\n'
                  '• Spotify Connect, which tells a Spotify client you already '
                  'have running to play a track. This needs Premium and an '
                  'active device.\n\n'
                  '• The 30-second preview clips Spotify publishes openly for '
                  'many tracks, streamed (never downloaded).\n\n'
                  'When neither is available for a track, AURIX says so '
                  'rather than showing a progress bar over silence.',
            ),

            const _Section(
              title: 'What is stored on your device',
              body:
                  'Your OAuth tokens are held in the Android Keystore or iOS '
                  'Keychain. Search history, settings and catalogue metadata '
                  'you have viewed are cached in app storage so the app opens '
                  'quickly and works offline. Audio is never stored. Logging '
                  'out removes all of it.',
            ),

            const _Section(
              title: 'What is sent anywhere',
              body:
                  'Requests go to Spotify and nowhere else. AURIX has no '
                  'server, no analytics and no third-party SDKs. Your listening '
                  'is between you and Spotify.',
            ),

            const _Section(
              title: 'Branding',
              body:
                  'The AURIX name, logo and interface are original. No '
                  'Spotify logo, icon, artwork or other protected asset is '
                  'reproduced in this app. Album and artist images are loaded '
                  "from Spotify's CDN and belong to their respective owners.",
            ),

            const SizedBox(height: AppSpacing.lg),

            const _LinkRow(
              icon: AurixGlyph.document,
              label: 'Spotify Developer Terms',
              url: AppConstants.spotifyTermsUrl,
            ),
            const _LinkRow(
              icon: AurixGlyph.terminal,
              label: 'Spotify Web API documentation',
              url: 'https://developer.spotify.com/documentation/web-api',
            ),
            const _LinkRow(
              icon: AurixGlyph.premium,
              label: 'About Spotify Premium',
              url: AppConstants.spotifyPremiumUrl,
            ),

            const SizedBox(height: AppSpacing.xxl),

            Center(
              child: TextButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: AppConstants.appName,
                  applicationVersion: _version,
                  applicationLegalese:
                      'Built with Flutter. Uses the official Spotify Web API.',
                ),
                child: const Text('Open source licences'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.headlineSmall),
          const SizedBox(height: AppSpacing.sm),
          Text(body, style: AppTypography.bodyMedium.copyWith(height: 1.65)),
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.icon, required this.label, required this.url});

  final AurixGlyph icon;
  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      contentPadding: EdgeInsets.zero,
      leading: AurixIcon(icon, size: 20, color: context.palette.textSecondary),
      title: Text(label, style: AppTypography.bodyLarge),
      trailing: AurixIcon(
        AurixGlyph.externalLink,
        size: 16,
        color: context.palette.textTertiary,
      ),
      minLeadingWidth: 20,
    );
  }
}
