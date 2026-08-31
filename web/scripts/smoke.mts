/**
 * End-to-end smoke test against a running API.
 *
 *     npm run build && npm start          # in one terminal
 *     npx tsx scripts/smoke.mts           # in another
 *
 * Exercises the request paths the Flutter app actually makes, over real HTTP,
 * against the real database — which is the only way to catch the class of bug a
 * unit test cannot see: a route that does not exist at the path the client
 * expects, a body key renamed in the port, a 204 that became a 200.
 *
 * Every account and row it creates is namespaced and removed at the end, so it
 * is safe to run against a live deployment. It is deliberately a script rather
 * than a Vitest suite: it tests the *deployed shape* of the API, not modules.
 */

export {};

for (const file of ['.env.local', '.env']) {
  try {
    process.loadEnvFile(file);
  } catch {
    // Fine.
  }
}

const BASE = process.env.SMOKE_BASE_URL ?? 'http://127.0.0.1:3000';
const API = `${BASE}/api/v1`;

let passed = 0;
let failed = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail?: unknown): void {
  if (condition) {
    passed++;
    console.log(`  ok   ${name}`);
  } else {
    failed++;
    failures.push(name);
    console.log(`  FAIL ${name}${detail === undefined ? '' : ` — ${JSON.stringify(detail)}`}`);
  }
}

interface Result {
  status: number;
  body: Record<string, unknown>;
  headers: Headers;
}

async function call(
  method: string,
  path: string,
  { token, body: payload }: { token?: string; body?: unknown } = {},
): Promise<Result> {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: {
      Accept: 'application/json',
      ...(payload !== undefined ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    ...(payload !== undefined ? { body: JSON.stringify(payload) } : {}),
  });

  const text = await response.text();
  let body: Record<string, unknown> = {};
  try {
    body = text.length > 0 ? JSON.parse(text) : {};
  } catch {
    body = { raw: text.slice(0, 200) };
  }
  return { status: response.status, body, headers: response.headers };
}

const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
const email = `aurix-smoke-${stamp}@example.invalid`;
const password = 'smoke-test-password-123';

const trackId = `smoke_track_${stamp}`;
const songId = `smoke_song_${stamp}`;
const track = {
  title: 'Blinding Lights',
  artist: 'The Weeknd',
  album: 'After Hours',
  durationMs: 200_040,
  artworkUrl: '',
  explicit: false,
  source: 'aurix',
};

let accessToken = '';
let refreshToken = '';
let uid = '';
let playlistId = '';

console.log(`AURIX smoke test — ${API}\n`);

// ---------------------------------------------------------------------------
console.log('health & public');
{
  const health = await fetch(`${BASE}/health`);
  const body = (await health.json()) as { ok?: boolean; db?: string };
  check('GET /health is 200 with db up', health.status === 200 && body.db === 'up', body);

  const methods = await call('GET', '/auth/methods');
  check(
    'GET /auth/methods offers password',
    methods.status === 200 && Array.isArray(methods.body.methods) &&
      (methods.body.methods as string[]).includes('password'),
    methods.body,
  );

  const theme = await call('GET', '/theme');
  check('GET /theme is public', theme.status === 200 && Boolean(theme.body.theme), theme.status);
  check(
    'GET /theme hides updatedBy from anonymous callers',
    !('updatedBy' in ((theme.body.theme ?? {}) as object)),
  );

  const version = await call('GET', '/theme/version');
  check('GET /theme/version', version.status === 200 && typeof version.body.version === 'number');

  const options = await call('GET', '/theme/options');
  check('GET /theme/options lists fonts', options.status === 200 && Array.isArray(options.body.fonts));
}

// ---------------------------------------------------------------------------
console.log('\nCORS');
{
  // Not for the mobile app — CORS is a browser mechanism a native Dart client
  // ignores. This is what the **Flutter web build** depends on, and its absence
  // is invisible from every other test in this repository: the API answers
  // perfectly, and the browser refuses the response.
  const origin = 'http://localhost:8080';

  const preflight = await fetch(`${API}/auth/login`, {
    method: 'OPTIONS',
    headers: {
      Origin: origin,
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Headers': 'authorization,content-type',
    },
  });

  check(
    'a preflight is answered without waking a route',
    preflight.status === 204,
    preflight.status,
  );
  check(
    'and grants the requesting origin',
    preflight.headers.get('access-control-allow-origin') === origin,
    preflight.headers.get('access-control-allow-origin'),
  );
  check(
    'and allows the Authorization header',
    // Without this every authenticated cross-origin request fails its
    // preflight — the failure that looks like "the API is down".
    (preflight.headers.get('access-control-allow-headers') ?? '')
      .toLowerCase()
      .includes('authorization'),
    preflight.headers.get('access-control-allow-headers'),
  );

  const actual = await fetch(`${BASE}/health`, { headers: { Origin: origin } });
  check(
    'an ordinary request carries the grant too',
    actual.headers.get('access-control-allow-origin') === origin,
    actual.headers.get('access-control-allow-origin'),
  );
  check(
    'and varies on Origin, so a cache cannot cross-serve it',
    (actual.headers.get('vary') ?? '').toLowerCase().includes('origin'),
    actual.headers.get('vary'),
  );
  check(
    'credentials are never allowed — the API authenticates by header, not cookie',
    actual.headers.get('access-control-allow-credentials') === null,
    actual.headers.get('access-control-allow-credentials'),
  );
  check(
    'and the wildcard is never used',
    actual.headers.get('access-control-allow-origin') !== '*',
  );
}

// ---------------------------------------------------------------------------
console.log('\nauthentication');
{
  const anon = await call('GET', '/auth/me');
  check('GET /auth/me without a token is 401 unauthenticated',
    anon.status === 401 && (anon.body.error as { code?: string })?.code === 'unauthenticated',
    anon.body);

  const bad = await call('GET', '/auth/me', { token: 'not-a-token' });
  check('a malformed token is rejected', bad.status === 401, bad.body);

  const registered = await call('POST', '/auth/register', {
    body: { email, password, name: 'Smoke Test' },
  });
  check('POST /auth/register is 201', registered.status === 201, registered.body);
  check('register returns the session shape',
    typeof registered.body.accessToken === 'string' &&
      typeof registered.body.refreshToken === 'string' &&
      typeof registered.body.expiresAt === 'string' &&
      typeof registered.body.user === 'object',
    Object.keys(registered.body));

  accessToken = String(registered.body.accessToken);
  refreshToken = String(registered.body.refreshToken);
  uid = String((registered.body.user as { uid?: string })?.uid ?? '');

  const user = registered.body.user as Record<string, unknown>;
  check('the account view never carries a password hash', !('passwordHash' in user));
  check('providers lists password', Array.isArray(user.providers) &&
    (user.providers as string[]).includes('password'), user.providers);

  const duplicate = await call('POST', '/auth/register', {
    body: { email, password, name: 'Duplicate' },
  });
  check('a second registration for one address is 409 email_in_use',
    duplicate.status === 409 && (duplicate.body.error as { code?: string })?.code === 'email_in_use',
    duplicate.body);

  const wrong = await call('POST', '/auth/login', { body: { email, password: 'wrong' } });
  check('a wrong password is 401 invalid_credentials',
    wrong.status === 401 && (wrong.body.error as { code?: string })?.code === 'invalid_credentials',
    wrong.body);

  const missing = await call('POST', '/auth/login', {
    body: { email: `absent-${stamp}@example.invalid`, password: 'wrong' },
  });
  check('an unknown account gives the identical error — no enumeration',
    missing.status === wrong.status &&
      (missing.body.error as { code?: string })?.code ===
        (wrong.body.error as { code?: string })?.code,
    missing.body);

  const login = await call('POST', '/auth/login', { body: { email, password } });
  check('POST /auth/login is 200', login.status === 200, login.body);
  accessToken = String(login.body.accessToken);

  const short = await call('POST', '/auth/register', {
    body: { email: `short-${stamp}@example.invalid`, password: 'abc', name: 'X' },
  });
  check('a short password is 400 bad_request with details',
    short.status === 400 && Array.isArray((short.body.error as { details?: unknown })?.details),
    short.body);

  const me = await call('GET', '/auth/me', { token: accessToken });
  check('GET /auth/me returns the account', me.status === 200 &&
    (me.body.user as { uid?: string })?.uid === uid, me.body);

  const rotated = await call('POST', '/auth/refresh', { body: { refreshToken } });
  check('POST /auth/refresh returns a new pair', rotated.status === 200 &&
    typeof rotated.body.refreshToken === 'string', rotated.status);

  const replay = await call('POST', '/auth/refresh', { body: { refreshToken } });
  check('replaying a spent refresh token is refused', replay.status === 401, replay.body);

  refreshToken = String(rotated.body.refreshToken);
  accessToken = String(rotated.body.accessToken);
}

// ---------------------------------------------------------------------------
console.log('\nprofile');
{
  const profile = await call('GET', '/profile/me', { token: accessToken });
  check('GET /profile/me', profile.status === 200, profile.status);

  const other = await call('GET', '/profile/some-other-uid', { token: accessToken });
  check("reading another account's profile is 403 forbidden",
    other.status === 403 && (other.body.error as { code?: string })?.code === 'forbidden',
    other.body);

  const own = await call('GET', `/profile/${uid}`, { token: accessToken });
  check('reading your own profile by uid works', own.status === 200, own.status);

  const avatar = await call('PUT', '/profile/me/avatar', {
    token: accessToken,
    body: { avatarId: 'avatar_05' },
  });
  check('PUT /profile/me/avatar', avatar.status === 200 &&
    (avatar.body.user as { avatarId?: string })?.avatarId === 'avatar_05', avatar.body);

  const stats = await call('GET', '/profile/me/stats', { token: accessToken });
  check('GET /profile/me/stats', stats.status === 200 &&
    typeof stats.body.likedTracks === 'number', stats.body);
}

// ---------------------------------------------------------------------------
console.log('\nlibrary');
{
  const like = await call('PUT', `/library/liked/${trackId}`, {
    token: accessToken,
    body: track,
  });
  check('PUT /library/liked/:id is 204', like.status === 204, like.status);

  const again = await call('PUT', `/library/liked/${trackId}`, {
    token: accessToken,
    body: track,
  });
  check('liking twice is idempotent', again.status === 204, again.status);

  const liked = await call('GET', '/library/liked', { token: accessToken });
  const tracks = (liked.body.tracks ?? []) as { id?: string }[];
  check('GET /library/liked returns the track once',
    liked.status === 200 && tracks.filter((t) => t.id === trackId).length === 1,
    tracks.length);
  check('the row carries id, not trackId',
    tracks.some((t) => t.id === trackId) && !tracks.some((t) => 'trackId' in t));

  const is = await call('GET', `/library/liked/${trackId}`, { token: accessToken });
  check('GET /library/liked/:id reports liked', is.status === 200 && is.body.liked === true);

  const among = await call('POST', '/library/liked/among', {
    token: accessToken,
    body: { trackIds: [trackId, 'not_liked_at_all'] },
  });
  check('POST /library/liked/among filters to the liked ones',
    among.status === 200 && Array.isArray(among.body.likedIds) &&
      (among.body.likedIds as string[]).length === 1,
    among.body);

  const played = await call('POST', '/library/recently-played', {
    token: accessToken,
    body: { trackId, track, position: 42 },
  });
  check('POST /library/recently-played is 204', played.status === 204, played.status);

  const history = await call('GET', '/library/recently-played', { token: accessToken });
  check('GET /library/recently-played returns the entry',
    history.status === 200 && (history.body.entries as unknown[]).length > 0,
    history.status);

  const unlike = await call('DELETE', `/library/liked/${trackId}`, { token: accessToken });
  check('DELETE /library/liked/:id is 204', unlike.status === 204, unlike.status);
}

// ---------------------------------------------------------------------------
console.log('\nplaylists');
{
  const create = await call('POST', '/playlists', {
    token: accessToken,
    body: { name: 'Smoke Playlist', description: 'created by the smoke test' },
  });
  check('POST /playlists is 201 with an id', create.status === 201 &&
    typeof create.body.id === 'string', create.body);
  playlistId = String(create.body.id);

  const list = await call('GET', '/playlists', { token: accessToken });
  check('GET /playlists includes it', list.status === 200 &&
    (list.body.playlists as { id?: string }[]).some((p) => p.id === playlistId));

  const entries = ['a', 'b', 'c'].map((suffix) => ({
    trackId: `${trackId}_${suffix}`,
    track: { ...track, title: `Track ${suffix.toUpperCase()}` },
  }));

  const write = await call('PUT', `/playlists/${playlistId}/tracks`, {
    token: accessToken,
    body: { tracks: entries },
  });
  check('PUT /playlists/:id/tracks writes in order', write.status === 200 &&
    write.body.written === 3, write.body);

  const read = await call('GET', `/playlists/${playlistId}/tracks`, { token: accessToken });
  const ordered = (read.body.tracks as { id: string }[]).map((t) => t.id);
  check('tracks come back in the written order',
    ordered.join(',') === entries.map((e) => e.trackId).join(','), ordered);

  const reorder = await call('POST', `/playlists/${playlistId}/reorder`, {
    token: accessToken,
    body: { orderedTrackIds: ordered, from: 0, to: 2 },
  });
  check('POST /playlists/:id/reorder answers with the rebalanced flag',
    reorder.status === 200 && typeof reorder.body.rebalanced === 'boolean', reorder.body);
  check('a single move does not rebalance the whole list',
    reorder.body.rebalanced === false && typeof reorder.body.position === 'number',
    reorder.body);

  const after = await call('GET', `/playlists/${playlistId}/tracks`, { token: accessToken });
  const afterIds = (after.body.tracks as { id: string }[]).map((t) => t.id);
  check('the moved track is where it was dropped',
    afterIds[afterIds.length - 1] === ordered[0], afterIds);

  const one = await call('GET', `/playlists/${playlistId}`, { token: accessToken });
  check('trackCount was recomputed',
    (one.body.playlist as { trackCount?: number })?.trackCount === 3, one.body.playlist);

  const rename = await call('PATCH', `/playlists/${playlistId}`, {
    token: accessToken,
    body: { name: 'Renamed Smoke Playlist' },
  });
  check('PATCH /playlists/:id is 204', rename.status === 204, rename.status);

  const remove = await call('POST', `/playlists/${playlistId}/tracks/remove`, {
    token: accessToken,
    body: { trackIds: [entries[0]!.trackId] },
  });
  check('POST /playlists/:id/tracks/remove reports the count',
    remove.status === 200 && remove.body.removed === 1, remove.body);

  const missing = await call('GET', '/playlists/does-not-exist', { token: accessToken });
  check('an unknown playlist is 404 not_found',
    missing.status === 404 && (missing.body.error as { code?: string })?.code === 'not_found',
    missing.body);
}

// ---------------------------------------------------------------------------
console.log('\ncatalogue');
{
  const sparse = await call('POST', '/catalog/songs', {
    token: accessToken,
    body: {
      songs: [{
        id: songId,
        title: 'Blinding Lights',
        artists: ['The Weeknd'],
        searchTokens: ['blinding', 'blindin', 'weeknd'],
      }],
    },
  });
  check('POST /catalog/songs creates', sparse.status === 200 && sparse.body.created === 1,
    sparse.body);

  const enrich = await call('POST', '/catalog/songs', {
    token: accessToken,
    body: {
      songs: [{
        id: songId,
        title: 'Blinding Lights',
        artists: ['The Weeknd'],
        album: 'After Hours',
        duration: 200040,
      }],
    },
  });
  check('a second write enriches rather than duplicating',
    enrich.status === 200 && enrich.body.updated === 1 && enrich.body.created === 0,
    enrich.body);

  const one = await call('GET', `/catalog/songs/${songId}`, { token: accessToken });
  const song = one.body.song as { album?: string; title?: string; id?: string };
  check('the merge filled the empty album', song?.album === 'After Hours', song);
  check('_id was mapped to id', song?.id === songId);

  const downgrade = await call('POST', '/catalog/songs', {
    token: accessToken,
    body: { songs: [{ id: songId, title: 'Blinding Lights', artists: ['The Weeknd'], album: '' }] },
  });
  check('an emptier submission changes nothing',
    downgrade.status === 200 && downgrade.body.written === 0, downgrade.body);

  const stillThere = await call('GET', `/catalog/songs/${songId}`, { token: accessToken });
  check('the album survived the emptier write',
    (stillThere.body.song as { album?: string })?.album === 'After Hours');

  const batch = await call('POST', '/catalog/songs/batch', {
    token: accessToken,
    body: { ids: [songId, 'absent_song_id'] },
  });
  const map = batch.body.songs as Record<string, unknown>;
  check('POST /catalog/songs/batch answers a map keyed by id',
    batch.status === 200 && songId in map && !('absent_song_id' in map),
    Object.keys(map));

  const search = await call('GET', `/catalog/songs/search?q=blinding`, { token: accessToken });
  check('GET /catalog/songs/search finds it by prefix',
    search.status === 200 && (search.body.songs as { id?: string }[]).some((s) => s.id === songId),
    (search.body.songs as unknown[])?.length);

  const empty = await call('GET', '/catalog/songs/search?q=', { token: accessToken });
  check('an empty query returns nothing rather than everything',
    empty.status === 200 && (empty.body.songs as unknown[]).length === 0);
}

// ---------------------------------------------------------------------------
console.log('\nadministration');
{
  const stats = await call('GET', '/admin/stats', { token: accessToken });
  check('a non-admin is refused with admin_only',
    stats.status === 403 && (stats.body.error as { code?: string })?.code === 'admin_only',
    stats.body);

  const users = await call('GET', '/admin/users', { token: accessToken });
  check('the user list is refused too', users.status === 403, users.status);

  const theme = await call('PUT', '/theme', {
    token: accessToken,
    body: { primaryColor: '#FF0000' },
  });
  check('a non-admin cannot repaint the app', theme.status === 403, theme.status);

  const anonymous = await call('PUT', '/theme', { body: { primaryColor: '#FF0000' } });
  check('an anonymous caller cannot either', anonymous.status === 401, anonymous.status);
}

// ---------------------------------------------------------------------------
console.log('\nshared catalogue');
{
  const search = await call('GET', '/shared-playlists/search?q=zzzznothing', {
    token: accessToken,
  });
  check('GET /shared-playlists/search answers a list',
    search.status === 200 && Array.isArray(search.body.playlists), search.body);

  const find = await call('GET', '/shared-playlists/find?source=spotify&sourceId=absent', {
    token: accessToken,
  });
  check('find answers null rather than 404',
    find.status === 200 && find.body.playlist === null, find.body);

  const mine = await call('GET', `/shared-playlists/imported-by/${uid}`, { token: accessToken });
  check('imported-by answers a list', mine.status === 200 && Array.isArray(mine.body.playlists));
}

// ---------------------------------------------------------------------------
console.log('\ncleanup');
{
  const deletePlaylist = await call('DELETE', `/playlists/${playlistId}`, { token: accessToken });
  check('DELETE /playlists/:id is 204', deletePlaylist.status === 204, deletePlaylist.status);

  const wrongPassword = await call('DELETE', '/auth/me', {
    token: accessToken,
    body: { password: 'not-the-password' },
  });
  check('deleting an account with the wrong password is refused',
    wrongPassword.status === 401, wrongPassword.body);

  const deleted = await call('DELETE', '/auth/me', { token: accessToken, body: { password } });
  check('DELETE /auth/me is 204', deleted.status === 204, deleted.body);

  const after = await call('GET', '/auth/me', { token: accessToken });
  check('the account is gone', after.status === 404 || after.status === 401, after.status);
}

// The catalogue song is shared data and outlives the account by design, so it is
// removed directly rather than through the API — there is no endpoint for it.
{
  const { collections, close } = await import('../src/server/db/mongo');
  const songs = await collections.catalogSongs();
  await songs.deleteOne({ _id: songId });
  await close();
}

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.log(`\nFailures:\n${failures.map((f) => `  - ${f}`).join('\n')}`);
  process.exit(1);
}
