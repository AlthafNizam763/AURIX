# AURIX architecture

AURIX is a Firebase application. Spotify is an optional import provider and,
for now, the playback provider for full tracks.

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
| User profile | `GET /me` | **Remove** → Firestore `/users/{uid}` |
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
Firebase       Import              Search                Playback
Auth +         MusicImport         SearchService         MusicPlaybackService
Firestore      Provider              │                     │
               ├ SpotifyImport       ├ LibrarySearch       └ PlayerController
               └ YouTubeImport       └ SpotifySearch          ├ App Remote
                                                              ├ Connect
                                                              └ local preview
```

Four independent seams. Firebase is the only one the app cannot start without.

### What the app requires

* **Firebase Auth** — identity. Email/password, with registration, sign-out,
  password reset and password change. Session persistence is Firebase's own.
* **Cloud Firestore** — every piece of user data. Offline persistence is on, so
  the library is readable and writable with no network.
* **Firebase Storage** — *not used*. Avatars are bundled assets and artwork is
  referenced from its source's CDN. Nothing is uploaded, so nothing needs a
  bucket, a moderation path, or a deletion story.
* **Cloud Functions** — *not used*. Nothing in the current feature set needs
  server-side code. The one place that would is account deletion, which must
  walk the subcollections before deleting the user document — see the note in
  `firestore.rules`.

---

## 3. Firestore schema

```
/users/{uid}                                AurixUser
  ├── /playlists/{playlistId}               Playlist
  │     └── /tracks/{trackId}               Track + position
  ├── /likedTracks/{trackId}                Track
  ├── /recentlyPlayed/{trackId}             Track + playedAt, position
  └── /settings/{settingId}                 reserved; nothing writes here yet
```

Everything a user owns is nested under their own document. That is the schema's
central decision: it makes the authorisation rule one line — `request.auth.uid
== uid` — and makes that one line cover every collection, including ones added
later. A flat top-level `playlists` collection with an `ownerUid` field would
need a rule per collection, would need every query to remember its `where`
clause or leak, and would fail open for any document written without the field.

### Documents

**`/users/{uid}`**
```jsonc
{ "uid": "...", "name": "...", "email": "...",
  "avatarId": "avatar_01",            // a bundled asset id, never a URL
  "createdAt": Timestamp, "updatedAt": Timestamp }
```

**`/users/{uid}/playlists/{playlistId}`**
```jsonc
{ "name": "...", "description": "...", "coverUrl": "...",
  "source": "aurix" | "spotify" | "youtube",
  "sourceId": "...",                  // the id at the source; null for AURIX's own
  "trackCount": 0,                    // denormalised so a grid of covers is one read
  "createdAt": Timestamp, "updatedAt": Timestamp }
```

**`.../tracks/{trackId}` and `/likedTracks/{trackId}`**
```jsonc
{ "title": "...", "artist": "...", "album": "...", "durationMs": 0,
  "artworkUrl": "...", "explicit": false,
  "source": "aurix", "sourceId": null,
  "spotifyId": null, "youtubeVideoId": null,
  "position": 1024.0,                 // playlist tracks only — see below
  "createdAt": Timestamp }
```

### Two decisions worth knowing

**Document ids are derived, not allocated.** `TrackKey` turns a track into
`spotify_4uLU6hMC`, `youtube_dQw4w9WgXcQ`, or `aurix_<title>-<artist>`. Three
things depend on it: liking is idempotent, re-importing updates rather than
duplicating, and the same song in Liked Songs and in two playlists is one
identity. A random id breaks all three, and breaks them silently.

**`position` is a double.** A playlist is ordered and a Firestore collection is
not, so the order is a field — and the choice of field decides what a reorder
costs. Integer indices mean moving one track from position 40 to position 2
renumbers 38 documents. Fractional ranks mean one write: to place a track
between two others, take the midpoint. New tracks append at `last + 1024`.

The failure mode is bounded and handled: repeatedly inserting between the same
pair halves the gap, and after ~50 such inserts no midpoint exists.
`FirestorePlaylistService` detects that and renumbers the playlist once — the
expensive operation, paid approximately never instead of on every drag.

---

## 4. Security rules

`firestore.rules`. The whole model is one predicate:

```
function isOwner(uid) { return request.auth != null && request.auth.uid == uid; }
```

applied to every path under `/users/{uid}`, with a `match /{document=**} { allow
read, write: if false; }` catch-all at both the user level and the database
level — so a collection added later fails loudly in development and gets its own
rule, rather than inheriting access silently.

Beyond ownership the rules enforce:

* **Length bounds on every string.** Not cosmetic: without them any signed-in
  user can write a 1 MiB string into their own document as often as they like,
  which is a storage-cost attack on the project owner. The bounds are generous
  for real content and ruinous for that.
* **`createdAt` is immutable** once set.
* **`avatarId` is bounded to 40 characters**, which is where "an avatar is a
  bundled asset id" stays true against a hand-crafted write that tries to make
  it a data: URI.
* **The user document cannot be deleted** by a client. Deleting it while its
  subcollections exist orphans every playlist and liked song: invisible to the
  owner, permanently billed, unreachable by any query.

Deploy with `firebase deploy --only firestore:rules,firestore:indexes`.

Rules run on Google's servers, not in the app. `flutter test` passing is **not**
evidence they are right — the only honest test is against the emulator.

---

## 5. Import

```
Spotify / YouTube / …
      │  MusicImportProvider   ← authenticate, getPlaylists,
      ▼                          getPlaylistTracks, disconnect
ImportedPlaylist / ImportedTrack     (descriptions, not records)
      │  MusicImportService    ← the one place a description becomes a record
      ▼
Firestore
      │
      ▼
AURIX UI
```

A provider produces **descriptions** and nothing else. It does not touch
Firestore, does not know a document id, and does not decide what an AURIX
playlist looks like. `MusicImportService` owns all of that — the document
layout, the de-duplication rule, the update-versus-create decision, the
batching — and those answers must be identical for every provider, so there is
one copy of them.

`YouTubeImportProvider` exists to check that claim. It compiles against the same
interface, is registered in the same list, and appears in the same UI, with only
its four methods left to fill in. Adding it required no change to the service,
the models, Firestore, or any screen.

### The rule about audio

Importing brings in **metadata and references**: titles, artists, album names,
durations, artwork URLs, and the track's id at the source. No audio. AURIX does
not download, cache, re-encode or store audio from Spotify or YouTube, does not
circumvent any protection, and writes nothing to Firebase Storage. The retained
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

Firestore's own persistence, switched on explicitly in `firestoreProvider` with
an unlimited cache. Every query is served from disk when the network is gone,
every write is queued and replayed on reconnect, and the snapshot listeners keep
firing throughout.

The manual cache that used to do this — `MetadataCache` over `SharedPreferences`,
with per-collection read/write helpers and a staleness flag — is gone from the
library path entirely. A second cache on top of Firestore's would be a second
answer to "what is in my library", and the two would disagree.

`MetadataCache` survives for the album/artist detail screens, which still read
an HTTP API and still need one.

---

## 9. Migration

`LocalDataMigration` runs once per uid, on the first session after sign-in.

A user upgrading from a Spotify-backed build has a cached library in
`SharedPreferences` and an avatar choice keyed by their *Spotify* account id.
After the upgrade they sign in to a new AURIX account with a Firebase uid that
has never seen any of it — so without this, their first launch shows an empty
library.

It **deletes nothing**. The local data stays exactly where it is, so an
interrupted run can start over — and starting over is safe because the document
ids are derived from the tracks themselves, so writing twice produces one
library.

The avatar case is the awkward one: there is no way to know which Spotify
account belonged to the person now signing in, so it takes the only stored
choice when there is exactly one and gives up when there are several. Showing
someone else's avatar is worse than showing the default.
