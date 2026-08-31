# Playlist import — how it works and how to set it up

AURIX imports a playlist from Spotify or YouTube Music by pasting its link. This
document covers the architecture, the credentials you have to supply, and — most
importantly — the two things that **cannot** be made to work, so that time is not
spent trying.

---

## The shape of it

```
                    ┌── Spotify ── OAuth ──┐
                    │                      │
 paste a link ──────┤                      ├── provider API
                    │                      │
                    └── YouTube ── OAuth ──┘
                                 ↓
                        playlist metadata
                                 ↓
                          track metadata
                                 ↓
                         AURIX normaliser
                                 ↓
                             MongoDB
                                 ↓
                          AURIX playlist
```

Every hop after "paste a link" happens **on the server**. The Flutter app posts
a URL to `POST /api/v1/music/import` and gets an AURIX playlist back; it holds no
client secret, no provider token, and no paging loop.

That is not only a security property. It is what makes a connection *reusable*:
the tokens are a row in MongoDB keyed on the AURIX user, so connecting Spotify
on a phone means the same account is already connected on a tablet.

### The files

| Concern | File |
| --- | --- |
| Link → `(provider, playlistId)` | `web/src/server/services/music/links.ts` |
| OAuth per provider | `web/src/server/services/music/providers.ts` |
| Token storage and refresh | `web/src/server/services/music/connections.ts` |
| Token encryption at rest | `web/src/server/services/music/crypto.ts` |
| Spotify reads | `web/src/server/services/music/spotify.ts` |
| YouTube reads | `web/src/server/services/music/youtube.ts` |
| Normalise and write | `web/src/server/services/music/import.ts` |
| Document ids | `web/src/server/services/music/keys.ts` |
| App-side client | `mobile/lib/data/services/api/api_music_service.dart` |
| Screen | `mobile/lib/features/import/import_playlist_screen.dart` |

---

## Authorization happens only when it is needed

The two providers genuinely differ, and the route asks for different things:

* **Spotify** has no unauthenticated read path at all. Every Web API call needs a
  token, and a playlist's *items* need a token belonging to that playlist's
  owner. So a connection is required before any Spotify import, and its absence
  comes back as `provider_auth_required` (HTTP 428) — which the app renders as a
  **Connect Spotify** button, not an error.
* **YouTube** serves a *public* playlist to a caller holding only an API key. So
  the connection is used if there is one and skipped if there is not. The user is
  asked to connect only when the key gets a refusal, which is what a private or
  unlisted playlist looks like from outside.

The user therefore never authorizes a provider in order to import something that
did not need it.

---

## The two things that cannot work

### 1. Somebody else's Spotify playlist

Since Spotify's February 2026 changes (enforced 9 March 2026),
`GET /playlists/{id}/items` is served **only to a playlist's owner or a
collaborator** and answers `403` to everyone else — while `GET /playlists/{id}`
still answers `200` with metadata for any playlist.

No credential, scope, quota mode or extended-access application changes this. It
is a policy about Spotify's data. AURIX reports it with a message naming the
playlist's owner and the account it is connected as; the remedy available to a
user is to save a copy to their own Spotify library and import that.

Spotify's own editorial playlists (`37i9dQZF1…` — Discover Weekly, Today's Top
Hits, RapCaviar) fall under the same rule and get their own message.

See `docs/API_LIMITATIONS.md` §2a for the full account.

### 2. Audio

Neither provider offers an endpoint that returns decodable audio, and both
forbid extracting it. AURIX imports what a playlist *is*, never what it sounds
like:

> song title · artist · album · artwork · duration · provider · provider track
> id · original playlist id · external URL · track order

The one audio URL that ever appears is Spotify's own published 30-second
`preview_url`, which is a link to Spotify's CDN and not a copy of anything. There
is no download step, no temporary file, and no upload of provider audio to AURIX
storage. If AURIX ever gains real audio files they will come from a source that
permits it — the user's own uploads, or a licensed provider — through a separate
service, and never through this path.

---

## Setting it up

Everything below goes in `web/.env.local` for development, or the Vercel project
environment for a deployment. **None of it goes in `mobile/.env`**, which ships
inside the app binary.

`PUBLIC_API_URL` must already be set — a provider cannot redirect a browser back
to a deployment with no public address, and every OAuth path is disabled while it
is empty.

### Spotify

1. <https://developer.spotify.com/dashboard> → your app → Settings.
2. Add the redirect URI, exactly:
   `{PUBLIC_API_URL}/api/v1/music/connections/spotify/callback`
3. Copy the Client ID and **Client secret**.

```dotenv
SPOTIFY_CLIENT_ID=…
SPOTIFY_CLIENT_SECRET=…
```

The mobile app's own `SPOTIFY_CLIENT_ID` in `mobile/.env` is a *different
concern* — it is the in-app PKCE flow used for playback, and it has no secret
because there is nowhere safe to put one in a binary. The import does not use it.

Scopes requested: `playlist-read-private`, `playlist-read-collaborative`,
`user-read-private`. Read-only, and no playback scope.

> **Development Mode**: the dashboard's User Management list must include every
> account that will connect, up to the 25-user cap. An account not on the list
> gets a Spotify error page at consent time.

### YouTube / YouTube Music

1. <https://console.cloud.google.com> → enable **YouTube Data API v3**.
2. Credentials → OAuth client ID → Web application. Add the redirect URI:
   `{PUBLIC_API_URL}/api/v1/music/connections/youtube/callback`
3. Credentials → API key, restricted to the YouTube Data API v3.

```dotenv
YOUTUBE_CLIENT_ID=…       # falls back to GOOGLE_CLIENT_ID
YOUTUBE_CLIENT_SECRET=…   # falls back to GOOGLE_CLIENT_SECRET
YOUTUBE_API_KEY=…         # public playlists, no consent screen
```

The API key is what makes a public playlist import with no sign-in at all, so it
is worth setting even if OAuth is configured.

Scope: `youtube.readonly`. There is no write scope — AURIX imports from YouTube
and never modifies anything there.

### Token encryption

```dotenv
# node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
MUSIC_TOKEN_KEY=…
```

Optional; falls back to a value derived from `JWT_SECRET`. Rotating it
invalidates every stored connection, which costs each user one press of Connect.

### Indexes

```bash
cd web && npm run indexes
```

Required — the unique index on `(uid, provider)` is what makes re-connecting an
update rather than a second row.

---

## Deduplication

Both document ids are **derived, never generated**:

| Thing | Identity | Example |
| --- | --- | --- |
| Playlist | `provider` + `providerPlaylistId` | `pl_spotify_22WMPdyCLdKfeRraLxZbMw` |
| Song | `provider` + `providerTrackId` | `spotify_4uLU6hMCjMI75M1A2tKUQC` |

So importing the same playlist twice writes to the same `_id` twice and the
second import *updates*. There is no read-then-write window to lose, which is
what makes it correct under concurrency: two devices importing at the same
moment converge on one document.

A re-import is also a **re-sync** — it adds what the source added, drops what the
source no longer lists, and rewrites the order from the source. That is why
"Sync playlist" in the playlist screen's menu posts the stored `sourceUrl` to the
same endpoint rather than having a code path of its own.

Songs are **merged, never replaced**: an incoming field only ever fills a stored
field that is empty. The shared catalogue is written by every user from whatever
their source carried, and replacing rows would make a song gain and lose its
album depending on who imported it last.

`mobile/lib/data/models/playlist_key.dart` and `track_key.dart` implement the
same two derivations for the client. They must stay in step;
`web/test/music-keys.test.ts` pins the vectors.

---

## Errors the client branches on

| Code | HTTP | Means | Remedy shown |
| --- | --- | --- | --- |
| `provider_auth_required` | 428 | No connection | **Connect Spotify** |
| `provider_reconnect_required` | 401 | Connection cannot be renewed | **Reconnect Spotify** |
| `provider_forbidden` | 403 | Playlist is not the connected account's | Explanation, no retry |
| `provider_not_found` | 404 | No such playlist | Check the link |
| `provider_unsupported_link` | 400 | Not a playlist link AURIX takes | Check the link |
| `provider_rate_limited` | 429 | Provider is throttling AURIX | Retry after |
| `provider_unavailable` | 503 | Deployment has no credentials | Nothing the user can do |

428 rather than 401 for `provider_auth_required` is deliberate: the request was
properly authenticated *to AURIX*, and a 401 would make the app refresh its own
session and then sign the user out when that changed nothing.

`provider_forbidden` deliberately gets **no retry button**. A playlist owned by
another account will refuse every retry for ever, and a button that cannot work
is worse than no button.

---

## Testing

```bash
cd web && npm test        # link parsing, both fetchers, keys, crypto, import
cd mobile && flutter test
```

`web/test/music-import.test.ts` runs against the real cluster in `.env.local` and
skips itself when there is none. It covers the claims that are claims *about
MongoDB* — dedupe on re-import, reconciliation, ordering, merge-not-overwrite,
an empty playlist, and a 500-track one.

The two fetcher suites stub `fetch`, because the cases worth pinning — a 403 on
page one, a token dying mid-page-three, a video made private after it was added
— are ones a live account cannot be made to produce on demand.
