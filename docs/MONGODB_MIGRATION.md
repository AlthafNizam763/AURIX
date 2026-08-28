# Firebase → MongoDB

What moved, what it cost, and what to do on the day you deploy it.

---

## The shape of it

AURIX used to be a Firebase application: Firebase Auth owned identity, Firestore
owned the data, and `firestore.rules` was the security boundary. The client
talked to Google directly.

It is now a client of its own API.

```
  BEFORE                                AFTER

  Flutter app                           Flutter app
      │                                     │  HTTPS + JWT
      ├── firebase_auth ──┐                 ▼
      └── cloud_firestore ┤             AURIX API  (server/, Node + Express)
                          ▼                 │  MongoDB driver
                    Google servers          ▼
                    firestore.rules      MongoDB Atlas
```

The single most important consequence: **the app no longer holds a database
credential, because it no longer has a database connection.** A connection
string compiled into a mobile binary is a connection string published to
everyone who installs it — an APK is a zip file and `.env` is an asset inside
it. `MONGODB_URI` therefore lives in `server/.env` and appears nowhere in the
Flutter half of this repository. `test/unit/env_redirect_test.dart` asserts that
`Env` has no way to read one.

---

## What does not carry over

**Firebase Auth accounts.** Every user has to register again.

This is not an oversight and there is no script that would fix it. Firebase
exports password hashes only in its own scrypt variant, with a project-specific
signer key, and no other system can verify one. The options were to keep
Firebase Auth alongside MongoDB — which leaves the migration half-done — or to
accept a one-time re-registration. The second was chosen deliberately.

Everything else moves: profiles, playlists, liked songs, play history, the
shared song catalogue and the shared playlist catalogue all have equivalents,
and the document shapes are unchanged (see *Data* below).

There is no automated data migration either, because there was no production
data to migrate. If you have some, the shapes below are close enough that a
Firestore export can be reshaped with a script — the field names are the same;
what changes is that the nesting moves from the path into indexed fields.

---

## Deploying it

```bash
# 1. The API
cd server
cp .env.example .env
#    Fill in MONGODB_URI, JWT_SECRET, JWT_REFRESH_SECRET.
#    Set BOOTSTRAP_ADMIN_EMAIL to the address that should be the first admin.
npm install
npm start                     # :4000, admin panel at /admin/

# 2. The app
cd ..
cp .env.example .env          # if you have not already
#    Set AURIX_API_BASE_URL (and the _ANDROID / _WEB variants).
flutter pub get
flutter run
```

Register in the app with the bootstrap admin address, then open
`http://localhost:4000/admin/` and sign in with the same account.

### Generating the secrets

```bash
node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
```

Run it twice. Changing either secret later signs every device out, which is the
correct response to a suspected leak and an unpleasant surprise otherwise.

### The base URL, which is the thing people get wrong

`localhost` means three different things:

| Where the app runs | What to set |
|---|---|
| Desktop, iOS simulator | `AURIX_API_BASE_URL=http://localhost:4000` |
| Android emulator | `AURIX_API_BASE_URL_ANDROID=http://10.0.2.2:4000` |
| Flutter web | `AURIX_API_BASE_URL_WEB=http://localhost:4000`, and add the origin to `CORS_ORIGINS` |
| A physical device | `AURIX_API_BASE_URL=http://<your-lan-ip>:4000` |

There is no built-in default. A silent fallback would make `Env.isConfigured`
permanently true and the in-app setup screen — the one surface that tells you
what to add — unreachable on exactly the build that needs it.

---

## Data

Firestore's nesting does not survive, and should not: MongoDB has no
subcollections, and modelling them as embedded arrays would break the two things
the nesting bought. The hierarchy moves from the *path* into *indexed fields*.

| Firestore | MongoDB | Keyed on |
|---|---|---|
| `/users/{uid}` | `users` | `uid` (unique), `email` (unique, case-insensitive) |
| `/users/{uid}/likedTracks/{trackId}` | `likedTracks` | `(uid, trackId)` unique |
| `/users/{uid}/recentlyPlayed/{itemId}` | `recentlyPlayed` | `(uid, itemId)` unique |
| `/users/{uid}/playlists/{id}` | `userPlaylists` | `(uid, playlistId)` unique |
| `/users/{uid}/playlists/{id}/tracks/{trackId}` | `userPlaylistTracks` | `(uid, playlistId, trackId)` unique |
| `/catalog/global/songs/{songId}` | `catalogSongs` | `_id` = `SongKey` |
| `/playlists/{playlistId}` | `globalPlaylists` | `_id` = `PlaylistKey` |
| `/playlists/{playlistId}/tracks/{trackId}` | `globalPlaylistTracks` | `(playlistId, trackId)` unique |
| — | `appConfig` | `_id: 'theme'` — new |
| — | `brandAssets.*` | GridFS — new |

The unique constraints are the schema, not an optimisation. `(uid, trackId)` on
liked tracks is what makes liking a song twice idempotent — the property
Firestore got from deriving the document id from `TrackKey`. Losing it would let
duplicates back in.

### The two shared collections

`catalogSongs` and `globalPlaylists` are still *shared*, and still not owned by
the account reading them. That is what makes an import a contribution to AURIX
rather than a private copy: a playlist imported by one user can be searched,
opened and played by every other.

Provenance lives in fields — `importedByUserId`, `importedBy`, `importedAt` —
and **not one of them narrows who may read**. Exactly two operations consult
`importedByUserId`: the delete, which only the importer may perform, and the
"playlists I imported" list, which is a presentation filter on the Library
screen. That distinction — *recorded, not enforcing* — is the whole design, and
it is now enforced by route handlers where it used to be enforced by
`firestore.rules`.

---

## Where the security boundary went

`firestore.rules` ran on Google's servers and was the last line of defence
against a hostile client. There is no equivalent, and there does not need to be
one: **the client can no longer reach the database at all.**

Every write goes through a route handler that has already resolved `req.user.uid`
from a signed token, and a per-user collection is only ever queried with that
uid spliced in by the handler — never with a uid taken from the request body.
That is the migration's one genuine security improvement: what used to be a rule
a client could try to talk past is now a query the client cannot phrase.

What replaced the *shape* half of the rules — the part that asserted a document
had the right fields and no others — is Zod validation in
`server/src/middleware/validate.js`. Unknown fields are stripped rather than
stored, so a compromised client cannot append arbitrary data to a document.

Three things are new and were not needed before, because Google was doing them:

- **Rate limiting** on the credential routes. Without it, `POST /login` is an
  offline password cracker with a network hop.
- **Password hashing.** bcrypt at cost 12.
- **Token rotation.** A refresh token is single-use; presenting one twice fails
  the second time, which makes replay detectable.

---

## Real-time, and what was lost

Every read in AURIX is a `Stream` — `watchPlaylists`, `watchLikedTracks`,
`watchTracks` — and the screens above them are `StreamProvider`s that rebuild
when a document changes. Firestore supplied that: a write echoed into every
listener on the device before it even reached the server.

An HTTP API supplies nothing of the kind. `LiveQueries`
(`lib/data/services/api/live_query.dart`) is what feeds those streams now. A
watched query fetches once, emits, and emits again whenever something
invalidates a matching key; every write invalidates the keys it affected.

**Be clear about what this is and is not.** Local changes propagate exactly as
they did — liking a song on the player still updates the heart on the library
screen behind it, on the next frame. Changes made on *another device* do not
arrive instantly; they arrive on the poll interval, which defaults to two
minutes. Genuine cross-device push needs a WebSocket or SSE channel on the API.
That is a worthwhile addition and it is not pretended to exist.

---

## Verification, honestly

What was run:

- `flutter analyze` — clean.
- `flutter test` — 868 tests, all passing.
- `npm test` in `server/` — 28 tests, all passing.

What was **not** run, and what that means:

- **The API has never been run against a live MongoDB.** The connection string
  in `.env.example` carries `<USERNAME>` / `<PASSWORD>` placeholders, so no
  connection was ever opened. Every route, index and aggregation is unexercised
  against a real server. The first thing to do on deployment is `npm start` and
  watch the boot log — it reports the database it connected to and the indexes
  it created.
- **No end-to-end sign-in was performed.** The auth flow is covered by unit
  tests on its pure parts (token derivation, validation schemas) and by
  inspection everywhere else.
- **Neither admin surface was opened in a browser or on a device.** The web
  panel's JavaScript and the Flutter Appearance screen both analyze and, in the
  Flutter case, have widget tests over their controls — but nobody has clicked
  through them.
- **The uploaded-font path is untested end to end.** `FontRegistry` downloads,
  registers and caches a font file; the logic is straightforward and the failure
  modes degrade to the bundled face, but no font has actually been uploaded and
  rendered.

The migration is complete in the sense that every Firebase call site has a
MongoDB equivalent and the app builds, analyzes and tests clean. It is not
complete in the sense of having been exercised against real infrastructure.

---

## Files worth reading first

| File | Why |
|---|---|
| `server/src/db/collections.js` | The schema, the indexes, and why each one exists |
| `server/src/middleware/auth.js` | The one rule that replaced `firestore.rules` |
| `lib/data/services/api/live_query.dart` | What replaced snapshot listeners, and its limits |
| `lib/core/network/aurix_api_client.dart` | Token attachment, refresh, and the session/network distinction |
| `lib/core/theme/theme_config.dart` | The theme system's three layers of defaulting |
| `docs/THEMING.md` | The appearance system end to end |
