import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// Renders a failure.
///
/// Takes an [ApiException] rather than a string so the message, the icon and
/// whether a retry button makes sense are all decided in one place — and so a
/// raw exception can never reach the screen. `ApiException.message` is already
/// written for humans; `debugDetail` is what stays in the logs.
class ErrorView extends StatelessWidget {
  const ErrorView({
    required this.error,
    this.onRetry,
    this.compact = false,
    this.title,
    super.key,
  });

  final ApiException error;
  final VoidCallback? onRetry;

  /// Inline variant for a failed shelf inside an otherwise healthy page.
  final bool compact;

  final String? title;

  @override
  Widget build(BuildContext context) {
    final canRetry = onRetry != null && error.kind != ApiFailureKind.cancelled;

    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.page,
          vertical: AppSpacing.lg,
        ),
        child: Row(
          children: [
            AurixIcon(_icon, size: 18, color: AppColors.textTertiary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                error.message,
                style: AppTypography.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (canRetry)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: const BoxDecoration(
                color: AppColors.surfaceElevated,
                shape: BoxShape.circle,
              ),
              child: AurixIcon(_icon, size: 34, color: _iconColor),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              title ?? _title,
              style: AppTypography.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              error.message,
              style: AppTypography.bodyMedium,
              textAlign: TextAlign.center,
            ),
            if (canRetry) ...[
              const SizedBox(height: AppSpacing.xxl),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ).animate().fadeIn(duration: AppConstants.medium),
    );
  }

  AurixGlyph get _icon {
    switch (error.kind) {
      case ApiFailureKind.offline:
        return AurixGlyph.offline;
      case ApiFailureKind.timeout:
        return AurixGlyph.hourglass;
      case ApiFailureKind.unauthorized:
        return AurixGlyph.lock;
      case ApiFailureKind.forbidden:
        return AurixGlyph.block;
      case ApiFailureKind.notFound:
        return AurixGlyph.search;
      case ApiFailureKind.rateLimited:
        return AurixGlyph.motion;
      case ApiFailureKind.serverError:
        return AurixGlyph.offline;
      case ApiFailureKind.parsing:
      case ApiFailureKind.cancelled:
      case ApiFailureKind.unknown:
        return AurixGlyph.warning;
    }
  }

  Color get _iconColor {
    switch (error.kind) {
      case ApiFailureKind.offline:
      case ApiFailureKind.timeout:
      case ApiFailureKind.rateLimited:
        return AppColors.warning;
      case ApiFailureKind.forbidden:
      case ApiFailureKind.unauthorized:
        return AppColors.info;
      default:
        return AppColors.error;
    }
  }

  String get _title {
    switch (error.kind) {
      case ApiFailureKind.offline:
        return "You're offline";
      case ApiFailureKind.timeout:
        return 'Taking too long';
      case ApiFailureKind.unauthorized:
        return 'Session expired';
      case ApiFailureKind.forbidden:
        return 'Not available';
      case ApiFailureKind.notFound:
        return 'Not found';
      case ApiFailureKind.rateLimited:
        return 'Slow down';
      case ApiFailureKind.serverError:
        return 'Spotify is having trouble';
      default:
        return 'Something went wrong';
    }
  }
}

/// A legitimately empty result — no data, no failure.
///
/// Kept distinct from [ErrorView] on purpose: an empty Liked Songs list is not
/// an error and should not be dressed as one.
class EmptyView extends StatelessWidget {
  const EmptyView({
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    super.key,
  });

  final AurixGlyph icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? AppSpacing.xl : AppSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AurixIcon(
              icon,
              size: compact ? 36 : 52,
              color: AppColors.textTertiary,
            ),
            SizedBox(height: compact ? AppSpacing.md : AppSpacing.xl),
            Text(
              title,
              style: compact
                  ? AppTypography.titleMedium
                  : AppTypography.headlineSmall,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                message!,
                style: AppTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.xl),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ).animate().fadeIn(duration: AppConstants.medium),
    );
  }
}

/// Slim banner shown above content when the device has no connection.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({this.message, this.onRetry, super.key});

  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceElevated,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.page,
            vertical: AppSpacing.sm + 2,
          ),
          child: Row(
            children: [
              const AurixIcon(AurixGlyph.offline, size: 16, color: AppColors.warning),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  message ?? "You're offline — showing saved details.",
                  style: AppTypography.bodySmall.copyWith(color: AppColors.textSecondary),
                ),
              ),
              if (onRetry != null)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  ),
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      ),
    ).animate().slideY(begin: -1, duration: AppConstants.medium, curve: Curves.easeOutCubic);
  }
}

/// Small inline spinner for "loading more" at the bottom of a paged list.
class PagingIndicator extends StatelessWidget {
  const PagingIndicator({this.visible = true, super.key});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox(height: AppSpacing.xxl);
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      ),
    );
  }
}
