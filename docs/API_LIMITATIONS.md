# Spotify Web API limitations, and how AURIX handles them

This document exists because the honest answer to "why does this app work that
way?" is usually "because that is what Spotify's API actually permits". Every
limitation below is real, is not a bug in AURIX, and cannot be worked around
without violating Spotify's Developer Terms — which this project does not do.

---

## 1. A third-party app cannot play Spotify audio directly

There is no endpoint that returns a decodable audio stream for a catalogue
track. The audio is DRM-protected and only Spotify's own clients and SDKs can
decode it.

**What AURIX does instead** — the two mechanisms Spotify authorises:

| Mechanism | What it is | Requirements |
|---|---|---|
| **Spotify Connect** | AURIX sends transport commands (`PUT /me/player/play`, `/pause`, `/next`, …) to a Spotify client the user already has running. That client plays the full track. | Spotify **Premium**, an **active device**, and the `user-modify-playback-state` scope. |
| **Preview clips** | Spotify publishes a 30-second MP3 at `track.preview_url` for many tracks. AURIX streams it with `just_audio`. | None — but see §2. |

**What AURIX will not do**: extract protected audio URLs, cache or download
audio, reverse-engineer private endpoints, or bypass Premium checks.

**When neither works**, `PlaybackResolver` returns `PlaybackMode.unavailable`
and the UI states the reason. The progress bar does not move and `isPlaying`
stays `false`. See `lib/playback/playback_mode.dart` and the tests in
`test/unit/playback_resolver_test.dart`, which pin this behaviour down.

---

## 1a. What App Remote does and does not give you

App Remote — binding to the Spotify app on the same phone — is the third
mechanism, and the one AURIX prefers on mobile. Four of its properties shape the
playback code and none of them can be worked around in Dart:

**State is pushed on change, not on a clock.** `subscribePlayerState` emits when
something happens — a track change, a pause, a seek — and then goes quiet. It
never ticks. Anything showing a moving position has to interpolate between
pushes and reconcile periodically, which is what the single ticker in
`PlayerController` does. A UI that only updated on push sits frozen mid-track;
that was a real bug.

**Artwork is an identifier, not a URL.** `Track.imageUri` is a
`spotify:image:…` string. Resolving it to pixels needs `SpotifySdk.getImage`,
which returns bytes — there is no https URL, so it cannot be handed to
`Image.network` or to an Android `MediaSession` as `artUri`. For a track AURIX
queued, the Web API artwork is already in hand. For a track Spotify moved to on
its own, AURIX resolves `GET /tracks/{id}` once and caches it.

**The Spotify queue is not readable.** App Remote exposes the *current* track
and nothing about what follows. AURIX therefore follows Spotify rather than
predicting it: when a track ends, the next one is whatever Spotify reports.

**Spotify's own media notification cannot be suppressed or taken over.** While
the Spotify app is playing it owns a `MediaSession` and posts its own
notification, and no third-party app may remove another app's session. AURIX
publishes its own session so its lock-screen controls drive Spotify and show the
current track — so on Android there are **two** media notifications during App
Remote playback. Which one Android surfaces in the media carousel is decided by
recency of session activity, not by either app. This is inherent to the
platform.

---

## 2. `preview_url` is null for most new apps

On **27 November 2024** Spotify stopped populating `preview_url` for
applications created on or after that date. Older apps kept it.

**Effect**: on a newly-registered developer app, the preview path is mostly
unavailable and playback falls back to Spotify Connect.

**How AURIX handles it**: `Track.hasPreview` is checked before any preview is
attempted. A track with no preview and no Connect device is shown as
unplayable, with the reason. Nothing is faked.

---

## 2a. A Spotify playlist can only be imported by its owner

**This is the single most important limitation in this document**, because it
is the one users hit and it looks exactly like a bug in AURIX.

Spotify's February 2026 API changes replaced `/playlists/{id}/tracks` with
`/playlists/{id}/items` in all four verbs, and enforcement landed on
**9 March 2026** — the old path now answers `403` to every caller, in every
quota mode. That part is a straightforward migration.

The part that is not a migration is who the replacement will answer for. From
[Get Playlist Items](https://developer.spotify.com/documentation/web-api/reference/get-playlists-items):

> "This endpoint is only accessible for playlists owned by the current user or
> playlists the user is a collaborator of."

and a `403` "will be returned if the user is neither the owner nor a
collaborator of the playlist."

Meanwhile `GET /playlists/{id}` **still answers `200`** with the name, the
cover, the owner and the track count for *any* playlist. So an application can
see everything about a playlist except what is in it.

### What that asymmetry produced

The reported symptom, verbatim:

```text
[aurix.import] No existing global playlist found
[aurix.http]   → GET /playlists/22WMPdyCLdKfeRraLxZbMw
[aurix.http]   ← 200 /playlists/22WMPdyCLdKfeRraLxZbMw
[aurix.playlist] Contents unavailable for playlist 22WMPdyCLdKfeRraLxZbMw
                 — Spotify refused both /items and /tracks for this application
```

Three separate things were going wrong at once, and only the first was obvious:

1. **The `/tracks` fallback could never succeed.** It was tried after `/items`
   failed, on the theory that which spelling answered depended on quota mode. It
   does not — `/tracks` is gone for everyone. The fallback only ever turned one
   refusal into two and wrote the misleading "refused both" line.
2. **The 403 was reported as "contents unavailable".** It is not an availability
   problem. It is Spotify saying the connected account does not own the
   playlist, which needs a completely different sentence because "try again" is
   not the remedy and never will be.
3. **The item field had been renamed.** `items.items.track` became
   `items.items.item`; `track` is still sent but is marked deprecated. Code
   reading only `track` works today and returns an empty playlist on the day
   Spotify drops the compatibility field.

### What AURIX does

Imports through the backend (`POST /api/v1/music/import`), which:

* calls `/playlists/{id}/items` only, and never the removed `/tracks` —
  `SpotifyEndpoints.playlistTracks` now throws if anything reaches for it;
* reads `item` first and `track` second;
* turns a `403` on the items endpoint into a message naming the playlist's
  owner and the account AURIX is connected as, so the user can tell whether they
  have connected the wrong one of two Spotify accounts.

### What AURIX will not do

Scrape the web player. The refusal is Spotify's decision about its own data, and
routing around it would violate the Developer Terms. A user who wants somebody
else's playlist in AURIX can save a copy to their own Spotify library and import
that — which is a real remedy, and is what the error says.

---

## 3. Endpoints AURIX no longer calls at all

Two rounds of restrictions — 27 November 2024 and February 2026 — closed a
group of endpoints to Development Mode applications. They do not fail
intermittently or for some accounts: they answer `403` to **every** request
this application will ever make.

So they were **removed from the codebase**, not wrapped in a try/catch. A
guarded call to a permanently dead endpoint still costs a round trip, still
delays the screen waiting for it, and still fills the log with `403`s that
look like a bug. There is no version of "retry politely" that improves on not
asking.

| Endpoint | Closed | Was used for | Replaced by |
|---|---|---|---|
| `GET /browse/new-releases` | Feb 2026 | "New releases", and the fallback for three other shelves | "Your albums" from `GET /me/albums` |
| `GET /browse/categories` | Feb 2026 | Genre/mood tiles | `MoodCatalogue.defaults` — local labels, live search behind each |
| `GET /browse/categories/{id}` | Feb 2026 | Category screen header | The label passed through the route |
| `GET /browse/categories/{id}/playlists` | Nov 2024 | Playlists behind a tile | `GET /search?q=genre:"…"&type=playlist` |
| `GET /browse/featured-playlists` | Nov 2024 | "Made for you" | `GET /me/playlists` |
| `GET /recommendations` | Nov 2024 | "Recommended for you" | Seed artists → their own discographies, interleaved |
| `GET /recommendations/available-genre-seeds` | Nov 2024 | genre seeds | `MoodCatalogue.defaults` |
| `GET /artists/{id}/related-artists` | Nov 2024 | "Fans also like" | Search by the artist's own genres |
| `GET /audio-features`, `/audio-analysis` | Nov 2024 | never used | — |

### The library endpoints moved — they did not close

February 2026 consolidated the per-entity library **writes** and the membership
check onto one path. The old paths answer `403` to a Development Mode app,
which is what produced `✗ 403 PUT /me/tracks — Forbidden` in the logs.

| Was | Now | Notes |
|---|---|---|
| `PUT /me/tracks`, `PUT /me/albums` | `PUT /me/library?uris=…` | |
| `DELETE /me/tracks`, `DELETE /me/albums` | `DELETE /me/library?uris=…` | |
| `PUT`/`DELETE /playlists/{id}/followers` | `PUT`/`DELETE /me/library?uris=…` | `public` flag has no equivalent |
| `GET /me/tracks/contains`, `/me/albums/contains` | `GET /me/library/contains?uris=…` | |
| `GET /playlists/{id}/followers/contains` | `GET /me/library/contains?uris=…` | |

Three differences break a naive port, and all three are absorbed in
`SpotifyUserService._libraryWrite` / `_libraryContains`:

* it takes **Spotify URIs**, not bare IDs;
* `uris` is a **query parameter**, not a JSON body — the old endpoints took
  `{"ids": [...]}`, and sending that now is a `400` rather than a `403`;
* the cap is **40** URIs, below every per-type limit it replaced (50 tracks,
  20 albums), so chunking is uniform.

Scope is unchanged: `user-library-read` to check, `user-library-modify` to
write. Both are already requested at login.

**The reads did not move.** There is no `GET /me/library` collection endpoint —
`GET /me/tracks` and `GET /me/albums` are undeprecated and remain the only way
to page saved items. Only the verbs were consolidated.

**Artist follows are not part of this.** `/me/library` documents its accepted
URI types as tracks, albums, episodes, shows, audiobooks, users and playlists;
`spotify:artist:` is absent, so artist follow/unfollow and
`GET /me/following/contains` stay where they are.

### What is still discovered at runtime

Whether *this* app is refused an optional endpoint varies by quota mode, so it
cannot be decided at compile time. Those calls go through
`SpotifyApiService.getBoolArray` or `tryGet`, which **remember a refusal for
the session** — it is paid for once rather than on every scroll.
`resetAvailability()` clears the memo when the session changes.

`SpotifyPlaylistService.isFollowing` deliberately does *not* use
`getBoolArray`: that helper flattens a refusal to an empty list, and
`result.first` on it would render "not saved" for a playlist the user may well
have saved. It returns `bool?` instead, where null means Spotify declined to
answer and the heart renders indeterminate rather than making a claim.

### Search is capped, not closed

`GET /search` works, with one trap: February 2026 cut the `limit` maximum from
50 to **10** for Development Mode apps. Asking for more is a flat `400`, so
search fails completely rather than returning a short page. AURIX clamps to 10
via `SpotifyApiService.clampSearchLimit`; paging is driven by how many items
are already loaded, so nothing else changes.

The main search screen requests `type=track,artist,album`. `playlist` is
omitted deliberately — a playlist search returns mostly `null` entries to a
Development Mode app, which would render as a permanently empty tab. It is
still used for the genre tiles, where an empty result degrades to an empty
grid rather than a dead tab.

Every fallback returns **real, live Spotify data**. Nothing in this app is
hardcoded catalogue content. The only static list is
`MoodCatalogue.defaults` in `lib/data/models/category.dart`, which holds
*labels and search queries* — the playlists behind each tile are fetched from
Spotify at tap time.

The pattern is implemented once, in `SpotifyApiService.tryGet`: it attempts the
restricted endpoint, returns `null` on 403/404, and lets the caller substitute.
An app that *does* hold extended quota automatically gets the richer data with
no code change.

**To request extended quota**: Spotify Developer Dashboard → your app →
*Extended Quota Mode* → submit for review. It requires a real, published
product and is not granted to hobby projects.

---

## 4. Spotify Connect requires Premium

Every write endpoint under `/me/player` returns `403 PREMIUM_REQUIRED` for a
free account. This is not negotiable and there is no free-tier equivalent.

**How AURIX handles it**: `UserProfile.product` is read at login, and
`hasPremiumProvider` gates the UI. The device picker
(`lib/features/player/device_picker_screen.dart`) explains the restriction
directly rather than presenting an empty list.

---

## 5. Spotify Connect requires an active device

With no device running Spotify, the player endpoints answer
`404 NO_ACTIVE_DEVICE`. A device that has been idle long enough also disappears
from `GET /me/player/devices`.

**How AURIX handles it**: `checkAvailability()` distinguishes *no devices*,
*only restricted devices*, *device idle* and *ready*, and each state gets its
own message and remedy. An idle device is woken with
`PUT /me/player` (transfer) before the play command is retried.

**Restricted devices** (`is_restricted: true`) — Chromecast, many car head
units — reject Web API control entirely. They are listed but greyed out, since
offering them would promise something that cannot work.

---

## 6. No push notifications, no server

AURIX has no backend. There is nothing to send a push notification from, and
Spotify does not push events to third-party apps. The Notifications settings
group controls the in-app notification centre only, and says so on screen.

Similarly, `/me/player` has no webhook or websocket for third parties — remote
playback state is **polled** every 4 seconds while Connect is driving playback
(`PlayerController._pollRemote`), with local extrapolation between polls so the
scrubber moves smoothly.

---

## 7. No "verified artist" flag

The Web API exposes no verification field. AURIX shows a **"Popular artist"**
marker derived from `popularity >= 70` rather than implying a verification
Spotify never asserted.

---

## 8. No bitrate control

The Web API has no audio-quality parameter. Bitrate is decided by whichever
Spotify client is doing the playing. The Audio Quality settings therefore
govern only what AURIX itself controls — whether to stream preview clips on a
metered connection — and the screen states this explicitly.

---

## 9. Paging and rate limits

* Most `limit` parameters cap at **50**; `SpotifyApiService.clampLimit`
  enforces this so a large library cannot produce a `400`.
* Batch endpoints cap at **20** (`/albums`) or **50** (`/artists`,
  `/tracks/contains`); `SpotifyApiService.chunk` splits automatically.
* `GET /me/player/recently-played` returns at most 50 entries and repeats a
  track per play; the home repository de-duplicates.
* Rate limits are enforced per app in a rolling 30-second window and are not
  published. `RetryInterceptor` honours `Retry-After` on 429 and backs off
  exponentially with jitter, so parallel home-screen requests do not retry in
  lockstep.

---

## 10. Market and track relinking

Catalogue availability is per-country. Omitting `market` returns tracks the
user cannot play, and disables track relinking — which shows up as songs that
silently refuse to start.

AURIX sends `market` on every catalogue request. Before the profile loads it
uses `from_token`; afterwards `SpotifyApiService.setMarketFromCountry` swaps in
the profile's ISO country code.

---

## 11. Playlist edits need a snapshot ID

`DELETE /playlists/{id}/tracks` and the reorder endpoint accept a
`snapshot_id`. Without it, a concurrent edit from another device shifts
positions and the wrong track is removed. AURIX always sends the snapshot it
loaded and stores the one returned.

---

## 12. Spotify serves no lyrics

There is no Web API endpoint for lyrics — not for plain text and not for
timestamps. Spotify's own clients get them through a private service that is
not part of the published API, and the Developer Terms forbid both calling
private endpoints and deriving lyrics from the Spotify client or its audio.

**What AURIX does instead**: lyrics come from a separate provider under its own
terms, behind the `LyricsProvider` interface in
`lib/data/services/lyrics_service.dart`. The shipped implementation is
**LRCLIB** — an open, community-contributed database with a public API that
needs no key and permits third-party clients. It supplies timestamped (LRC)
lyrics where contributors have made them and plain text otherwise, which is
why the UI has both a synced and an unsynced mode.

Two properties of the design are deliberate:

**The lyrics client never sees a Spotify token.** It is built with its own
`Dio` instance rather than `spotifyDioProvider`, because that one attaches the
user's bearer token via `AuthInterceptor` to everything it sends. A provider
receives a title, an artist and a duration — never a token, never a Spotify
URI.

**Swapping the provider is one line.** `lyricsProviderProvider` in
`app_providers.dart` is the only place the choice is made. A deployment with a
commercial lyrics licence writes another `LyricsProvider` and changes that
line; no screen knows the difference.

**Matching is by metadata, so it can miss.** A lyrics database is keyed on
title/artist/duration, not on Spotify IDs. AURIX asks the exact-match endpoint
first (with duration, which separates a radio edit from the album cut), then
falls back to search, and **rejects a hit whose length differs by more than 20
seconds** — better no lyrics than lyrics that drift further out of sync the
longer the track runs. When nothing matches, the screen says so; nothing is
guessed or generated.

---

## Manual verification checklist

These cannot be covered by automated tests, because they need a real Spotify
account and a second device. They are the checks to run before shipping:

- [ ] Sign in with a **Premium** account → open Spotify on a laptop → the
      device appears in the picker → tapping a track plays it there.
- [ ] Sign in with a **free** account → the device picker explains the Premium
      requirement → previews still play if the app has them.
- [ ] Kill the network mid-session → offline banner appears → cached album and
      library screens still open.
- [ ] Play a preview → background the app → audio continues, notification
      controls work, lock-screen controls work.
- [ ] Revoke the app at spotify.com/account/apps → next request 401s → the app
      returns to login with an explanation rather than a crash.
- [ ] Share a track → the link opens in Spotify or a browser.
- [ ] Like a track in the player → the heart fills → the same track's heart is
      already filled in the playlist behind it → it appears in Liked Songs
      without reopening the screen. Unlike it → all three reverse.
- [ ] Open the lyrics on a well-known track → synced lines highlight and
      auto-scroll → tapping a line seeks → open one on an obscure B-side →
      "Lyrics unavailable" rather than a crash or wrong words.
