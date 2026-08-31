import 'package:equatable/equatable.dart';

import 'json_utils.dart';

/// One artwork rendition. Spotify returns a size-ordered list per object.
class SpotifyImage extends Equatable {
  const SpotifyImage({required this.url, this.width, this.height});

  final String url;
  final int? width;
  final int? height;

  factory SpotifyImage.fromJson(Map<String, dynamic> json) => SpotifyImage(
    url: Json.str(json, 'url'),
    width: Json.intOrNull(json, 'width'),
    height: Json.intOrNull(json, 'height'),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
  };

  int get area => (width ?? 0) * (height ?? 0);

  @override
  List<Object?> get props => [url, width, height];
}

/// Size-aware selection over an artwork list.
///
/// Spotify usually returns 640 / 300 / 64 px renditions. Picking the right one
/// matters: a 640px bitmap in a 48px list row wastes decode time and memory
/// across a 50-row list, and a 64px bitmap behind a full-screen player looks
/// like a mistake.
extension SpotifyImageList on List<SpotifyImage> {
  /// Largest available — full-screen player, immersive headers.
  String? get largestUrl {
    if (isEmpty) return null;
    final sorted = [...this]..sort((a, b) => b.area.compareTo(a.area));
    return sorted.first.url;
  }

  /// Smallest available — list rows, avatars, notification artwork.
  String? get smallestUrl {
    if (isEmpty) return null;
    final withSize = where((i) => i.area > 0).toList();
    if (withSize.isEmpty) return first.url;
    withSize.sort((a, b) => a.area.compareTo(b.area));
    return withSize.first.url;
  }

  /// The smallest rendition at least [minEdge] px on its shorter side, falling
  /// back to the largest available when nothing is big enough.
  String? bestFor(double minEdge) {
    if (isEmpty) return null;
    final target = minEdge.ceil();
    final candidates = where((i) {
      final edge = i.width ?? i.height ?? 0;
      return edge >= target;
    }).toList();

    if (candidates.isEmpty) return largestUrl;
    candidates.sort((a, b) => a.area.compareTo(b.area));
    return candidates.first.url;
  }

  /// Mid-size rendition for carousel cards.
  String? get cardUrl => bestFor(300);
}
