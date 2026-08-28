import '../../../core/constants/aurix_endpoints.dart';
import '../../../core/network/aurix_api_client.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/aurix_user.dart';
import 'aurix_session_store.dart';
import 'live_query.dart';

/// The AURIX profile — the replacement for `FirestoreProfileService`.
///
/// ## The profile and the account are one document now
///
/// Firebase kept them in two places: the Auth record held the email and the
/// verification flag, the `/users/{uid}` document held the name and the avatar.
/// They were written by different calls and could disagree, and
/// `ensureProfile` existed largely to reconcile them.
///
/// MongoDB holds one document, so that whole class of drift is gone.
/// [ensureProfile] survives because the app still calls it on every sign-in and
/// it still does something useful — it fills in fields an older record predates
/// — but it can no longer be the thing that repairs a split-brain, because
/// there are no longer two brains.
class ApiProfileService {
  ApiProfileService({
    required AurixApiClient client,
    required AurixSessionStore session,
    required LiveQueries live,
  }) : _client = client,
       _session = session,
       _live = live;

  final AurixApiClient _client;
  final AurixSessionStore _session;
  final LiveQueries _live;

  /// The profile, as a stream.
  ///
  /// Two sources feed it, which is deliberate. [AurixSessionStore.changes]
  /// carries the copy held on the device and fires the instant anything local
  /// changes it — a rename, an avatar pick — so those land on the next frame
  /// with no request at all. [LiveQueries] re-fetches on the poll interval so a
  /// change made on another device eventually arrives.
  ///
  /// Merging them means the common case is free and the rare case still works,
  /// which is exactly the trade Firestore's listener made for us.
  Stream<AurixUser?> watch(String uid) {
    return _live.watch<AurixUser?>(LiveKeys.user(uid), () => read(uid));
  }

  /// The locally-held copy, updated on every local change.
  ///
  /// Used by the router, which needs an answer synchronously enough that a
  /// network round trip would flash the login screen at a signed-in user.
  Stream<AurixUser?> watchLocal() => _session.changes();

  Future<AurixUser?> read(String uid) async {
    try {
      final response = await _client.get(AurixEndpoints.profile(uid));
      final body = response['user'];
      if (body is! Map<String, dynamic>) return null;
      return AurixUser.fromDocument(uid, body);
    } on Object catch (error) {
      AppLogger.warn('Could not read the profile for $uid', scope: 'profile', error: error);
      rethrow;
    }
  }

  /// Returns the profile, filling in anything an older record is missing.
  ///
  /// Idempotent, and called on every sign-in.
  ///
  /// [name] only fills a *gap* — the server never overwrites a name the user has
  /// set with one the device happened to remember. That rule lives on the
  /// server rather than here, because it is the kind of rule a second client
  /// would otherwise have to reimplement and get subtly wrong.
  ///
  /// [emailVerified] is accepted and ignored. It is a server-owned fact now;
  /// the parameter survives so the call sites did not have to change, and this
  /// comment is here so the next reader does not go looking for where it is
  /// written.
  Future<AurixUser> ensureProfile({
    required String uid,
    required String email,
    String name = '',
    bool emailVerified = false,
  }) async {
    final response = await _client.post(
      AurixEndpoints.profileEnsure,
      body: <String, dynamic>{
        if (name.trim().isNotEmpty) 'name': name.trim(),
        if (email.trim().isNotEmpty) 'email': email.trim(),
      },
    );

    final body = response['user'];
    if (body is! Map<String, dynamic>) {
      throw StateError('The API did not return a profile for $uid');
    }

    final user = AurixUser.fromDocument(uid, body);
    await _session.saveUser(user);
    return user;
  }

  Future<void> update(String uid, {String? name, String? avatarId}) async {
    if (name == null && avatarId == null) return;

    final response = await _client.patch(
      AurixEndpoints.profileMe,
      body: <String, dynamic>{
        'name': ?name?.trim(),
        'avatarId': ?avatarId,
      },
    );

    await _applied(uid, response);
  }

  Future<void> setAvatar(String uid, String avatarId) async {
    final response = await _client.put(
      AurixEndpoints.profileAvatar,
      body: <String, dynamic>{'avatarId': avatarId},
    );
    await _applied(uid, response);
  }

  /// Counts for the profile screen, without reading the rows behind them.
  Future<({int likedTracks, int playlists, int recentlyPlayed})> stats() async {
    final response = await _client.get(AurixEndpoints.profileStats);
    return (
      likedTracks: (response['likedTracks'] as num?)?.toInt() ?? 0,
      playlists: (response['playlists'] as num?)?.toInt() ?? 0,
      recentlyPlayed: (response['recentlyPlayed'] as num?)?.toInt() ?? 0,
    );
  }

  /// Stores the returned profile and wakes every watcher.
  Future<void> _applied(String uid, Map<String, dynamic> response) async {
    final body = response['user'];
    if (body is Map<String, dynamic>) {
      await _session.saveUser(AurixUser.fromDocument(uid, body));
    }
    _live.invalidate(LiveKeys.user(uid));
  }
}
