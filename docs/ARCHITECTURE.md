# AURIX architecture

AURIX is a client of its own API, backed by MongoDB. Spotify is an optional
import provider and, for now, the playback provider for full tracks.

This document is the map of that: what the Spotify dependencies were, what they
became, and where the seams are. It is written for the next person to change
this code, so it says *why* as often as *what*.

---

## 1. The Spotify dependency map, before

At the start of this refactor, Spotify was the backend. 1,162 references across
97 of the 129 Dart files. What that actually meant, by area:

| Area | Endpoint / SDK | Verdict |
|---|---|---|
| Authentication | `accounts.spotify.com` PKCE, `SpotifyAuthService` | **Move** → import provider |
| User profile | `GET /me` | **Remove** → the `users` collection |
| Liked songs | `GET/PUT/DELETE /me/tracks`, `/me/tracks/contains` | **Remove** → `/users/{uid}/likedTracks` |
| Playlists | `GET /me/playlists`, `/playlists/{id}/items`, add/remove/reorder | **Remove** → `/users/{uid}/playlists` |
| Saved albums | `GET/PUT/DELETE /me/albums` | **Delete** — no AURIX equivalent |
| Followed artists | `GET/PUT/DELETE /me/following` | **Delete** — no AURIX equivalent |
| Recently played | `GET /me/player/recently-played` | **Remove** → `/users/{uid}/recentlyPlayed` |
| Top tracks / artists | `GET /me/top/*` | **Delete** — Home is the user's own library now |
| Browse / categories | `GET /browse/*` | **Delete** — already restricted by Spotify since Nov 2024 |
| Recommendations | `GET /recommendations` | **Delete** |
| Search | `GET /search` | **Move** → one `SearchProvider` among several |
| Album / artist detail | `GET /albums/{id}`, `/artists/{id}` | **Keep**, isolated — see §6 |
| Playback (Connect) | `GET/PUT /me/player/*` | **Keep**, behind `MusicPlaybackService` |
| Playback (App Remote) | `spotify_sdk`, vendored `.aar` | **Keep**, behind `MusicPlaybackService` |
| Preview audio | `track.preview_url` + `just_audio` | **Keep** — the only audio AURIX decodes itself |

The four verdicts map exactly onto the four the brief asked for: *remove*,
*move to the import provider*, *keep temporarily inside the playback provider*,
*delete*.

---

## 2. The architecture, after

```
Flutter UI
    │
    ├── Riverpod providers (features/*/providers)
    │
    ▼
Repositories  (data/repositories)
    │
    ├──────────────┬──────────────────┬─────────────────────┐
    ▼              ▼                  ▼                     ▼
AURIX API      Import              Search                Playback
(HTTPS + JWT)  MusicImport         SearchService         MusicPlaybackService
    │          Provider              │                     │
    ▼          ├ SpotifyImport       ├ LibrarySearch       └ PlayerController
MongoDB        └ YouTubeImport       └ SpotifySearch          ├ App Remote
                                                              ├ Connect
                                                              └ local preview
```

Four independent seams. The API is the only one the app cannot start without.

### The one thing to understand about the backend

**The app has no database connection.** It has an HTTP client pointed at a
server that does.

That is not an implementation detail — it is the reason the architecture has a
server in it at all. A MongoDB connection string compiled into a mobile binary
is a connection string published to everyone who installs it: an APK is a zip
file, and `.env` is an asset inside it. `MONGODB_URI` therefore lives in
`server/.env` and appears nowhere in the Flutter half of this repository;
`test/unit/env_redirect_test.dart` asserts that `Env` has no way to read one.

```
Flutter app  ──HTTPS + JWT──▶  AURIX API (server/)  ──driver──▶  MongoDB Atlas
   no credentials                holds the URI
```

See `docs/MONGODB_MIGRATION.md` for what moved and what it cost.

### What the app requires

* **The AURIX API** (`server/`) — Node, Express, and the official MongoDB
  driver. Identity, all user data, the shared catalogues and the theme
  configuration. Set `AURIX_API_BASE_URL`; there is deliberately no default.
* **MongoDB** — reached by the API and by nothing else. Atlas or self-hosted;
  the app cannot tell.
* **GridFS** — uploaded logos, app icons and font files, in the same database.
  Nothing else is uploaded: avatars are bundled assets and artwork is referenced
  from its source's CDN, so there is no moderation path and no deletion story
  to build.
* **Firebase** — *not used*. Removed entirely; see the migration doc for what
  did not carry over.

---

## 3. MongoDB schema

```
users                    { uid, email?, phone?, passwordHash?, name, avatarId, isAdmin }
identities               { uid, provider, subject, email }         unique (provider, subject)
refreshTokens            { tokenHash, uid, expiresAt }             TTL
actionTokens             { tokenHash, uid, kind, expiresAt }       TTL
otpCodes                 { destination, purpose, codeHash, attempts }  TTL, unique (destination, purpose)
otpSends                 { destination, createdAt }                TTL — the per-number send ledger
authStates               { state, provider, intent, redirectUri }  TTL — an OAuth flow in progress
authGrants               { codeHash, kind, payload }               TTL — what the app redeems

likedTracks              { uid, trackId, ...track }                unique (uid, trackId)
recentlyPlayed           { uid, itemId, ...entry, playedAt }       unique (uid, itemId)
userPlaylists            { uid, playlistId, ...playlist }          unique (uid, playlistId)
userPlaylistTracks       { uid, playlistId, trackId, position }    unique (uid, playlistId, trackId)

catalogSongs             { _id: SongKey, ..., searchTokens[] }     shared
globalPlaylists          { _id: PlaylistKey, ..., importedByUserId } shared
globalPlaylistTracks     { playlistId, trackId, position }         unique (playlistId, trackId)

appConfig                { _id: 'theme', ... }
brandAssets.files/.chunks                                          GridFS
```

Firestore's nesting does not survive, and should not: MongoDB has no
subcollections, and modelling them as embedded arrays would break the two things
the nesting bought. The hierarchy moves from the *path* into *indexed fields* —
`(uid, playlistId, trackId)` is what `/users/{uid}/playlists/{id}/tracks/{tid}`
used to be.

The unique constraints are the schema, not an optimisation. `(uid, trackId)` on
liked tracks is what makes liking a song twice idempotent, which is the property
Firestore got from deriving the document id from `TrackKey`.

The full mapping, field by field, is in `docs/MONGODB_MIGRATION.md`.

`users.email` and `users.phone` are **sparse** unique indexes, and the sparsity
is load bearing rather than tidy: an account created from a phone number has no
email address at all, and a non-sparse unique index would permit exactly one
such account and refuse the second. `createUser` therefore omits the field
entirely rather than writing `''` or `null`, which is what keeps the index
honest. `ensureIndexes` rebuilds an index whose options have changed — that is
how a deployment that predates phone sign-in acquires the sparse version.

`identities` is a collection rather than an array on the user document because
the query that matters runs the other way round: sign-in starts from a provider
and a subject and has to find the uid. See §4a.

### The two shared collections

`catalogSongs` and `globalPlaylists` are deliberately **not** owned by the
account reading them. They are what make an import a contribution to AURIX
rather than a private copy: a playlist imported by one user can be searched,
opened and played by every other.

Provenance lives in fields — `importedByUserId`, `importedBy`, `importedAt` —
and not one of them narrows who may read. Exactly two operations consult
`importedByUserId`: the delete, which only the importer may perform, and the
"playlists I imported" list, which is a presentation filter. *Recorded, not
enforcing.*

---

## 4. Authorisation

`firestore.rules` is gone, and there is no equivalent — because there does not
need to be one. **The client can no longer reach the database at all.**

The whole model is one rule, in `server/src/middleware/auth.js`:

> Every per-user collection is queried with a uid, and **that uid comes from the
> verified bearer token and from nowhere else.** No route handler reads a uid
> out of a request body or a path parameter and uses it as a filter.

That is the migration's one genuine security improvement: what used to be a rule
a hostile client could try to talk past is now a query the client cannot phrase.
Where a route does take a `:uid` in its path — the profile read — `requireSelf`
asserts it equals the token's before the handler runs.

What replaced the *shape* half of the rules — the part asserting a document had
the right fields and no others — is Zod validation in
`server/src/middleware/validate.js`. Unknown fields are **stripped rather than
stored**, so a compromised client cannot append arbitrary data to a document,
and every string carries the same length bounds the rules used to enforce. Those
bounds are not cosmetic: without them any signed-in user can write a 1 MiB
string as often as they like, which is a storage-cost attack on the operator.

Three things are new, because Google used to do them:

* **Rate limiting** on the credential routes. Without it `POST /login` is an
  offline password cracker with a network hop — and bcrypt at cost 12 makes each
  guess expensive for the server too, so the limiter protects its CPU as well.
* **Password hashing.** bcrypt, cost 12. The hash never leaves `services/users.js`;
  `publicUser()` exists so that no route can serialise a user document straight
  to a response.
* **Token rotation.** A refresh token is single-use — presenting one twice fails
  the second time, because the first use deleted it, which makes replay
  detectable.

Unlike the rules, all of this runs in a process this repository builds and
`npm test` exercises. It has **not** been run against a live database — see the
verification section of `docs/MONGODB_MIGRATION.md`.

---

## 4a. Identity — six ways in, one account

AURIX signs people in with an email and password, a phone number, or one of four
OAuth providers. Every one of them ends at the same place: `buildSession()` in
`server/src/services/session.js`, which returns `{ user, accessToken,
refreshToken, expiresAt }` and nothing else. The client has exactly one piece of
code that reads that — `ApiAuthService._storeSession` — and it does not know or
care which door was used.

```
POST /auth/login              ─┐
POST /auth/phone/verify       ─┤
POST /auth/oauth/exchange     ─┼──▶ buildSession() ──▶ the same session payload
POST /auth/link/confirm       ─┤
POST /auth/refresh            ─┘
```

Nothing downstream of that behaves differently by method. The access token
carries a uid, an email and an admin flag; it does not record whether a password
or an Apple ID was involved, because a route that cared would be a route that
treats some accounts as second class.

### Where the secrets are

The app never performs an OAuth flow itself, and holds no client secret for any
provider. It cannot: a secret compiled into an APK is a secret published to
everyone who installs it.

```
 app ── POST /auth/oauth/google/start ─────────────▶ API
     ◀── { authorizationUrl } ──────────────────────

 app ── opens a system browser ────────────────────▶ Google
                       (the user consents)
     ◀── 302 to {PUBLIC_API_URL}/…/callback ───────  API
                       code ⇄ tokens   ← THE CLIENT SECRET IS USED HERE
                       tokens ⇄ profile
                       profile ⇄ an AURIX account
     ─── 302 to aurix://login-callback?code=… ─────▶ app

 app ── POST /auth/oauth/exchange { code } ────────▶ API
     ◀── a session, or a link challenge ────────────
```

What crosses back to the app is a single-use AURIX grant, never a provider
token. The final redirect is checked against an exact-match allow-list
(`OAUTH_APP_REDIRECTS`) — without one, `?redirect_uri=` would turn the API into
an open redirector with a session attached to it.

Google's and Apple's `id_token`s are read without a JWKS signature check, and
that is deliberate rather than an omission: they are read out of the body of a
TLS response to a request *this server made directly* to `oauth2.googleapis.com`
/ `appleid.apple.com`, which is the case both providers document as not
requiring verification. `iss`, `aud`, `exp` and the per-transaction `nonce` are
still asserted, because TLS says who sent a token and not what is in it.

### Why one person cannot become two accounts

The `identities` collection maps `(provider, subject)` → `uid`, with a **unique
index on the pair**. The provider's own immutable id is the key, not the email:
addresses change, get reassigned by corporate IT, and in Apple's case may be a
per-application relay.

Every social sign-in produces exactly one of three outcomes
(`services/identities.js`):

| Situation | Outcome |
| --- | --- |
| `(provider, subject)` is already in the table | Sign in. One indexed lookup. |
| New identity, and no account holds its verified address | Create an account, attach the identity. |
| New identity, and a **verified** address that an account already holds | **Link challenge.** Neither sign in nor create. |

The third case is why nobody accumulates duplicate accounts, and why linking is
a challenge rather than an automatic merge: an AURIX account can claim an
address nobody ever proved they read, because registration does not block on the
confirmation email. Auto-linking on a name match would hand a Google identity —
and the library behind it — to whoever registered first with that address. The
caller proves ownership with the account's password, or with a code mailed to
it, and then the two become one.

An address is only *matchable* when the provider asserts it is verified and it
is not an Apple private relay. An unverified address is worthless for this —
anyone can type anyone's address into a GitHub profile — and a relay address is
minted per application, so it could never match another account anyway.

### Phone codes

`services/otp.js`. What makes six digits safe is not the six digits; it is four
limits, all enforced server-side and all configurable: a five-minute life, five
attempts per code counted *on the code* rather than on the connection, five
sends per number per hour, and a unique index on `(destination, purpose)` so
requesting a new code invalidates the last. Only the SHA-256 is stored, and the
comparison is constant-time.

The plaintext leaves the process by exactly one route — an SMS to the number
that asked for it — and this is stricter than the rule password-reset links
follow. The asymmetry is deliberate: a reset link goes to an address the account
already owns and is useless without the mailbox, while a phone code is a
*complete* sign-in credential for whatever number was typed into an
unauthenticated endpoint. So there is no console fallback and no development
value in the response; `deliverSignInCode` in `services/sms.js` is the only
function given a plaintext code, and it returns a boolean so no caller can
propagate the value.

That makes SMS a hard dependency of the method rather than a nicety.
`env.phoneSignInEnabled` gates it in one place: with no transport it is absent
from `GET /auth/methods`, so the login screen draws no Phone button, and
`POST /auth/phone/start` throws `otp_unavailable` before `issueOtp` runs — so a
server that cannot deliver never mints a credential, never spends the caller's
hourly allowance, and never invalidates a code they are still holding. Delivery
is also checked *after* the send: a provider that refuses causes the code to be
cleared rather than left live for a message that never arrived.

`OTP_DEV_DELIVERY=file` exists so the flow is buildable without an SMS account.
It is read through `isProduction` in `config/env.js`, so no route, flag or
request can opt back into it, and it writes to a git-ignored file rather than to
a response, an error or the console.

### Removing a method

`DELETE /auth/methods/:provider` refuses to remove the last one. It is the only
account operation in AURIX that can lock its owner out irreversibly: an account
with no identity left has no sign-in path *and* no recovery path, because a
reset needs an address to send to.

### What is not verified

None of this has been run against live Google, Apple, Facebook or GitHub
credentials, or against a real SMS provider — see the verification note at the
end of this document. The provider modules are written from each provider's
documented flow; the parts that can be checked without them (phone
normalisation, the matchable-address rule, the redirect allow-list, the session
shape) are covered by `server/test/auth.test.js` and
`test/widget/sign_in_methods_test.dart`.

---

## 5. Import

```
Spotify / YouTube / …
      │  MusicImportProvider   ← authenticate, getPlaylists,
      ▼                          getPlaylistTracks, disconnect
ImportedPlaylist / ImportedTrack     (descriptions, not records)
      │  MusicImportService    ← the one place a description becomes a record
      ▼
The AURIX API
      │
      ▼
AURIX UI
```

A provider produces **descriptions** and nothing else. It does not touch the
API, does not know a document id, and does not decide what an AURIX
playlist looks like. `MusicImportService` owns all of that — the document
layout, the de-duplication rule, the update-versus-create decision, the
batching — and those answers must be identical for every provider, so there is
one copy of them.

`YouTubeImportProvider` exists to check that claim. It compiles against the same
interface, is registered in the same list, and appears in the same UI, with only
its four methods left to fill in. Adding it required no change to the service,
the models, the API, or any screen.

### The rule about audio

Importing brings in **metadata and references**: titles, artists, album names,
durations, artwork URLs, and the track's id at the source. No audio. AURIX does
not download, cache, re-encode or store audio from Spotify or YouTube, does not
circumvent any protection, and stores no audio bytes anywhere. The retained
`spotifyId` / `youtubeVideoId` exist so playback can hand the track to that
service's own authorised client — not so AURIX can fetch its stream.

### The session

`authenticate()` runs the provider's sign-in; `disconnect()` clears what it
created. AURIX holds no standing relationship with another service between
imports.

There is one documented exception, in `ImportController._disconnectQuietly`:
when Spotify is also the *active playback provider*, revoking mid-song would
stop the music from a screen about importing. This is the last coupling between
the import path and the playback path, and it disappears the moment playback
moves to a provider that is not Spotify.

---

## 6. Playback

```
UI  →  MusicPlaybackService  →  PlayerController  →  App Remote / Connect / preview
```

`MusicPlaybackService` is the seam. Its vocabulary is `play`, `pause`, `resume`,
`skipNext`, `skipPrevious`, `seek`, `setQueue`, `toggleShuffle`, `cycleRepeat` —
and it names nothing Spotify-specific.

Behind it, unchanged, is `PlayerController`. It was wrapped rather than
rewritten, deliberately: it is 1,900 lines, it is the only thing in AURIX that
can currently produce audio, and it already implements every method on the
interface. **No playback logic moved in this refactor**, which is why background
playback, the media notification, lock-screen controls, the Dynamic Island and
App Remote resynchronisation all behave exactly as they did.

Its three mechanisms, in the order the resolver prefers them:

1. **Spotify App Remote** — commands the Spotify app on this phone. Full track.
2. **Spotify Connect** — commands a Spotify device elsewhere. Full track, Premium.
3. **Local preview** — a 30-second preview URL through `just_audio`. The only
   audio AURIX decodes itself.

**A track AURIX owns with no `spotifyId` and no preview URL cannot be played.**
`Track.spotifyUri` returning null is what makes that a compile-time fact rather
than a runtime surprise — the nullable getter forced every call site to decide
what to do about it, and the resolver now reports "unplayable" rather than
sending `spotify:track:aurix_some-slug` to a Connect device.

That is not a bug in this layer. It is the honest state of a music app with no
licensed audio source of its own, and it is the thing a future provider fixes —
by implementing this interface and changing one line in
`musicPlaybackServiceProvider`.

### Album and artist detail

The one part of AURIX still reading the Spotify Web API outside the import flow.
AURIX has no catalogue: an imported track carries a `spotifyId` and a title, and
"go to the album" is a question only the source can answer. These screens work
when Spotify is reachable and show an empty state when it is not.

Nothing on Home, Library, Liked Songs, Playlist or Profile reaches them. That is
the property that matters: Spotify being unavailable costs two detail screens,
not the app.

---

## 7. Search

`SearchService` fans a query across every available `SearchProvider` and merges
the results in priority order.

* **`LibrarySearchProvider`** (priority 0) — the user's own liked tracks and
  playlists. Always available, needs no credentials, works offline.
* **`SpotifySearchProvider`** (priority 100) — the Spotify catalogue, available
  only while an import session is live.

The library outranks any catalogue deliberately: a user searching for a song in
their own playlists should find *their copy*, which is playable and which they
can add to a playlist, rather than an identical-looking catalogue entry that is
not in their library.

One provider failing costs its section of the results, not the page.

---

## 8. Offline

**This regressed in the MongoDB migration, and the honest summary is short: the
library is no longer readable or writable without a network.**

Firestore shipped offline persistence. Every query was served from disk when the
network was gone, every write was queued and replayed on reconnect, and the
snapshot listeners kept firing throughout — for the price of one settings line.
Nothing about an HTTP API gives that for free, and nothing here replaces it.

What still works with no network:

* The app launches, and it launches **branded** — the theme configuration is
  cached on the device and applied on the first frame, and a downloaded custom
  font is cached beside it. See `docs/THEMING.md`.
* The session survives. Tokens are read from the platform keystore at boot, so
  a signed-in user stays signed in and is not shown the login screen.
* Whatever is already on screen stays on screen. A failed refresh emits nothing
  rather than clearing a list or throwing — see `LiveQueries`.
* Album and artist detail still read `MetadataCache`, which is unchanged.
* Playback of an already-resolved track is unaffected.

What does not:

* Opening a screen whose data has not been fetched this session shows its error
  state.
* Liking a song, editing a playlist or recording a play fails and is **not**
  queued for retry.

Restoring parity is a real piece of work rather than a setting: it needs a local
store for the library, a write-ahead queue with replay on reconnect, and a
conflict rule for a row edited on two devices while both were offline. Firestore
had answers to all three. The seam for it is `LiveQueries` plus the API service
layer, which is where a cache-then-network read and an outbox would go.

`MetadataCache` survives for the album/artist detail screens, which still read
an HTTP API and still need one. It is deliberately *not* used for the library:
a second answer to "what is in my library" is a second source of truth, and the
two would disagree.

---

## 9. Migration

`LocalDataMigration` runs once per uid, on the first session after sign-in.

A user upgrading from a Spotify-backed build has a cached library in
`SharedPreferences` and an avatar choice keyed by their *Spotify* account id.
After the upgrade they sign in to a new AURIX account whose uid has never seen
any of it — so without this, their first launch shows an empty library.

It applies equally to a user upgrading across the MongoDB migration, who has to
register again and arrives with a second new uid. See
`docs/MONGODB_MIGRATION.md`.

It **deletes nothing**. The local data stays exactly where it is, so an
interrupted run can start over — and starting over is safe because the document
ids are derived from the tracks themselves, so writing twice produces one
library.

The avatar case is the awkward one: there is no way to know which Spotify
account belonged to the person now signing in, so it takes the only stored
choice when there is exactly one and gives up when there are several. Showing
someone else's avatar is worse than showing the default.
