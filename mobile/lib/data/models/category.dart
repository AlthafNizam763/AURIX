import 'package:equatable/equatable.dart';

import 'json_utils.dart';
import 'spotify_image.dart';

/// A browse category — the "Chill", "Workout", "Focus" tiles on Home.
class Category extends Equatable {
  const Category({
    required this.id,
    required this.name,
    this.icons = const [],
    this.searchTerm,
  });

  final String id;
  final String name;
  final List<SpotifyImage> icons;

  /// The Spotify search that populates this category.
  ///
  /// This is the only way a category is filled now:
  /// `/browse/categories/{id}/playlists` has been restricted since November
  /// 2024 and is no longer called. Null means "use the category name".
  final String? searchTerm;

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    id: Json.str(json, 'id'),
    name: Json.str(json, 'name', fallback: 'Category'),
    icons: Json.list(json, 'icons', SpotifyImage.fromJson),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'icons': icons.map((i) => i.toJson()).toList(),
    if (searchTerm != null) 'search_term': searchTerm,
  };

  String? get iconUrl => icons.largestUrl;
  String get query => searchTerm ?? name;

  @override
  List<Object?> get props => [id, name, icons, searchTerm];
}

/// The mood and genre shelf shown on Home and on Search.
///
/// This list *is* the catalogue. `/browse/categories` was removed from
/// Development Mode apps in February 2026, so there is no remote source for
/// these tiles any more.
///
/// It is not fabricated Spotify content: each entry is a label plus a real
/// Spotify search query, and tapping one runs that search live. The hardcoded
/// part is the menu, not the music.
abstract final class MoodCatalogue {
  static const List<Category> defaults = <Category>[
    Category(id: 'chill', name: 'Chill', searchTerm: 'chill'),
    Category(id: 'workout', name: 'Workout', searchTerm: 'workout'),
    Category(id: 'focus', name: 'Focus', searchTerm: 'focus instrumental'),
    Category(id: 'sleep', name: 'Sleep', searchTerm: 'sleep ambient'),
    Category(id: 'party', name: 'Party', searchTerm: 'party hits'),
    Category(id: 'pop', name: 'Pop', searchTerm: 'genre:pop'),
    Category(id: 'rock', name: 'Rock', searchTerm: 'genre:rock'),
    Category(id: 'hiphop', name: 'Hip-Hop', searchTerm: 'genre:hip-hop'),
    Category(id: 'edm_dance', name: 'Electronic', searchTerm: 'genre:electronic'),
    Category(id: 'jazz', name: 'Jazz', searchTerm: 'genre:jazz'),
    Category(id: 'indie_alt', name: 'Indie', searchTerm: 'genre:indie'),
    Category(id: 'rnb', name: 'R&B', searchTerm: 'genre:r-n-b'),
  ];

  /// Search terms shown as "Popular searches" before the user has typed
  /// anything and has no history.
  static const List<String> popularSearches = <String>[
    'Today\'s hits',
    'Lo-fi beats',
    'Acoustic covers',
    'Running',
    '90s throwback',
    'Deep focus',
    'Jazz classics',
    'Road trip',
  ];
}
