/// Barrel export for the data models.
///
/// Screens import this one file rather than a dozen paths; the models
/// themselves import each other directly to keep the dependency graph honest.
library;

export 'album.dart';
export 'artist.dart';
export 'aurix_user.dart';
export 'auth_method.dart';
export 'auth_session.dart';
export 'avatar.dart';
export 'category.dart';
export 'home_feed.dart';
export 'media_source.dart';
export 'paging.dart';
export 'playback.dart';
export 'playlist.dart';
export 'saved_item.dart';
export 'search_results.dart';
export 'spotify_image.dart';
export 'track.dart';
export 'track_key.dart';
export 'user_profile.dart';
