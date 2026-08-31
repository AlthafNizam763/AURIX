# AURIX API

The REST API the Flutter app speaks. Served by the Next.js application in
`web/`.

- **Base URL** — `https://your-deployment.vercel.app`
- **Prefix** — `/api/v1` on everything except `/health`
- **Transport** — JSON, UTF-8. `https` in production: every request carries a
  bearer token, and a token on an unencrypted connection is a token anyone on
  the network has.

Every path below is relative to the prefix, so `/auth/login` is
`https://…/api/v1/auth/login`.

---

## Conventions

### Success

There is **no envelope**. A response is the object itself, keyed by what it
contains:

```jsonc
{ "tracks": [ … ] }              // collections
{ "playlist": { … } }            // a single resource, or null
{ "user": { … } }                // any account
{ "id": "aB3xY…" }               // 201, on create
                                 // 204, on a write that returns nothing
```

A single-resource read answers `{ "playlist": null }` rather than 404 where
"not there" is an ordinary answer — the client is asking about an id it derived
locally, and absence is information, not failure. Routes that 404 are noted.

### Errors

```jsonc
{
  "error": {
    "code": "invalid_credentials",
    "message": "That email and password do not match.",
    "details": [ { "path": "email", "message": "…" } ]
  }
}
```

`message` is written to be shown to a user. `details` appears only on schema
failures. Outside production a 500 also carries `error.debug`.

**Branch on `code`, never on `message`.** The messages are copy and may change;
the codes are the contract.

| Code | HTTP | Meaning |
|---|---|---|
| `bad_request` | 400 | Malformed or failed validation |
| `weak_password` | 400 | Below eight characters |
| `invalid_email` | 400 | Not an address |
| `invalid_phone` | 400 | Not E.164, and no country code configured |
| `invalid_auth_state` | 400 | A stale, forged or replayed browser callback |
| `invalid_credentials` | 401 | Wrong password **or** no such account |
| `unauthenticated` | 401 | Missing or invalid bearer token |
| `token_expired` | 401 | Valid token, past its expiry — refresh |
| `invalid_code` | 401 | Wrong one-time code |
| `code_expired` | 401 | Correct but too late |
| `forbidden` | 403 | Not yours |
| `admin_only` | 403 | Administrators only |
| `not_found` | 404 | |
| `conflict` | 409 | Generic uniqueness violation |
| `email_in_use` | 409 | |
| `phone_in_use` | 409 | |
| `identity_in_use` | 409 | That provider account belongs to another user |
| `last_sign_in_method` | 409 | Removing it would lock the account |
| `payload_too_large` | 413 | |
| `unsupported_media_type` | 415 | Bytes are not the declared kind |
| `rate_limited` | 429 | With `Retry-After` |
| `internal` | 500 | Message is always generic |
| `otp_unavailable` | 503 | Phone sign-in not configured |
| `provider_unavailable` | 503 | That provider not configured |
| `unavailable` | 503 | A dependency is down |

### Authentication

```
Authorization: Bearer <accessToken>
```

Access tokens last 30 minutes. On `token_expired`, `POST /auth/refresh` with the
refresh token; it returns a new pair and **invalidates the one you sent**. A
refresh token presented twice fails the second time — that is replay detection,
not a bug.

### CORS

Only relevant to **browser** clients — the Flutter web build, or anything else
calling from another origin. A native Android or iOS client ignores CORS
entirely and needs none of this.

`CORS_ORIGINS` on the deployment is a comma-separated exact-match allow-list.
Empty reflects whatever origin asks, which is right for local development and
wrong in production.

- Preflights are answered with **204** and cached for 24 hours.
- `Authorization`, `Content-Type` and `Accept` are permitted on requests.
- `RateLimit-*` and `Retry-After` are readable on responses.
- `Access-Control-Allow-Credentials` is **never** sent, and the wildcard `*` is
  never used. The API authenticates by header, not cookie, so there is nothing
  for a browser to attach — and allowing credentials would turn the permissive
  development default into a CSRF surface.

A browser request that fails with no useful error, while the same call succeeds
from `curl`, is almost always an origin missing from that list.

### Rate limiting

Per IP, counted in the database so the limit holds across instances. Limited
routes carry `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset`; a
429 adds `Retry-After`.

| Bucket | Window | Production limit | Routes |
|---|---|---|---|
| `credentials` | 15 min | 20 | register, login, password change |
| `reset` | 60 min | 5 | password forgot, verification resend |
| `otp_start` | 15 min | 15 | phone start |
| `otp_verify` | 15 min | 30 | phone verify, phone link |
| `oauth_start` | 15 min | 30 | oauth start |
| `oauth_exchange` | 15 min | 60 | oauth exchange |
| `link` | 15 min | 20 | account link code, confirm |

Development allowances are 10×.

### The session payload

Returned by **every** sign-in door, plus refresh and link-confirm. One shape:

```jsonc
{
  "user":         { /* account, below */ },
  "accessToken":  "eyJ…",
  "refreshToken": "…",
  "expiresAt":    "2026-10-27T12:00:00.000Z",

  // Present only where relevant to the screen about to be drawn:
  "device":   "Pixel 8",
  "provider": "google",
  "created":  true,
  "linked":   true
}
```

### The account object

```jsonc
{
  "uid": "…",
  "name": "Alex",
  "email": "alex@example.com",
  "phone": "+447700900123",
  "avatarId": "avatar_01",
  "emailVerified": true,
  "phoneVerified": false,
  "emailIsPrivateRelay": false,
  "isAdmin": false,
  "providers": ["password", "google"],
  "createdAt": "2026-01-01T00:00:00.000Z",
  "updatedAt": "2026-01-02T00:00:00.000Z"
}
```

`passwordHash` is never present. `emailIsPrivateRelay` marks an Apple per-app
forwarding address: deliverable, but not an address the user would recognise as
theirs. `providers` is what lets Settings refuse to unlink the last method.

### The track object

Sent flat, on writes and reads alike. Unknown fields are **dropped, not stored**.

| Field | Type | Default |
|---|---|---|
| `title` | string ≤500 | `"Unknown track"` |
| `artist` | string ≤500 | `""` |
| `album` | string ≤500 | `""` |
| `durationMs` | int 0…86400000 | `0` |
| `artworkUrl` | string ≤2048 | `""` |
| `explicit` | bool | `false` |
| `source` | string ≤32 | `"aurix"` |
| `sourceId`, `spotifyId`, `youtubeVideoId`, `previewUrl` | string, nullable | — |

On reads the row also carries `id` (the track key) and `createdAt`. Storage keys
never cross the wire.

---

## Health

### `GET /health`

Public. Outside `/api/v1` — it reports on the deployment, not on a version.

```jsonc
{ "ok": true, "service": "aurix-api", "db": "up", "commit": "a1b2c3d" }
```

**503** when the database is unreachable, so a monitor treats a live process
with a dead database as the outage it is.

---

## Authentication

### `GET /auth/methods`

Public. What this deployment can actually serve.

```jsonc
{ "methods": ["password", "phone", "google", "apple"] }
```

A provider whose credentials are absent is omitted, so the login screen draws no
button for it. Nothing secret is disclosed.

### `POST /auth/register`

Public · rate limited `credentials`

```jsonc
{ "email": "alex@example.com", "password": "…", "name": "Alex", "device": "Pixel 8" }
```

**201** → session. Password minimum is **8** characters and must match
`AppConstants.minPasswordLength` in the app.

The verification email is sent in the background; a mail failure does not fail
the registration.

Errors: `email_in_use` · `weak_password` · `invalid_email` · `rate_limited`

### `POST /auth/login`

Public · rate limited `credentials`

```jsonc
{ "email": "alex@example.com", "password": "…", "device": "Pixel 8" }
```

**200** → session.

> A wrong password and an unknown address return the **identical** error, and
> the bcrypt comparison runs either way so the two take the same time. Both
> halves are deliberate: this endpoint must not disclose which addresses are
> registered.

Errors: `invalid_credentials` · `rate_limited`

### `POST /auth/refresh`

Public — the token is the credential.

```jsonc
{ "refreshToken": "…" }
```

**200** → session, with a **new** refresh token. The old one is invalid
immediately.

Errors: `unauthenticated` (spent, revoked, or unknown) · `token_expired`

### `POST /auth/logout`

Public. `{ "refreshToken": "…" }` → **204**.

Unauthenticated on purpose: a client whose access token has already expired must
still be able to sign out. Revoking an unknown token is a no-op.

### `GET /auth/me` · `PATCH /auth/me` · `DELETE /auth/me`

User.

`GET` → `{ "user": … }`.

`PATCH` `{ "name"?, "avatarId"? }` → `{ "user": … }`. `bad_request` if empty.

`DELETE` `{ "password"? }` → **204**. The password is **required where the
account has one** — a live session is a weaker claim than a re-typed password,
and deletion is irreversible. Accounts created by a social provider or a phone
code have none, and for those it is omitted.

Deletes liked tracks, history, playlists, tokens and linked identities. **Does
not** delete anything the account contributed to the shared catalogue: other
users are listening to it.

### `DELETE /auth/methods/{provider}`

User. `provider` ∈ `password` `phone` `google` `apple` `facebook` `github`.

→ `{ "user": … }`. Refuses the **last** method with `last_sign_in_method`: an
account with no identity left has no sign-in path and no recovery path either.

### `POST /auth/password/change`

User · rate limited `credentials`

```jsonc
{ "currentPassword": "…", "newPassword": "…" }
```

**200** → session. `currentPassword` is required where one exists; for an
account that has none this route *sets* the first one, authorised by the live
session.

**Every other session is revoked.** The caller keeps working because the
response carries a fresh pair.

### `POST /auth/password/forgot`

Public · rate limited `reset`

`{ "email": "…" }` → **200**, always:

```jsonc
{ "ok": true, "message": "If that address has an AURIX account, a reset link is on its way." }
```

Identical whether or not the account exists — a reset form must not be an
address-enumeration oracle. Outside production with no SMTP configured, the
response also carries `devToken` so the flow is testable.

### `POST /auth/password/reset`

Public · rate limited `reset`. `{ "token", "password" }` → `{ "ok": true }`.

Consumes the token and revokes every session.

### `POST /auth/email/verify/send` · `POST /auth/email/verify`

`send` — user, rate limited `reset` → `{ "ok": true, "alreadyVerified"? }`.

`verify` — public, `{ "token" }` → `{ "ok": true, "user": … }`.

---

## Phone sign-in

Requires an SMS provider. Without one the method is **switched off**, not
degraded: `GET /auth/methods` omits it and `start` refuses with
`otp_unavailable` **before a code is generated**.

A six-digit code is safe because of its limits, not its length: five-minute
expiry, five attempts, five sends per hour per number, and requesting a new one
burns the old. Only a hash is stored.

### `POST /auth/phone/start`

Optional auth · rate limited `otp_start`

```jsonc
{ "phone": "+44 7700 900123", "intent": "signIn" }
```

`intent: "link"` requires a bearer token. →

```jsonc
{ "ok": true, "message": "OTP sent successfully", "phone": "+44•••••123",
  "expiresInSeconds": 300, "resendInSeconds": 30 }
```

Errors: `invalid_phone` · `phone_in_use` · `otp_unavailable` · `rate_limited`

### `POST /auth/phone/verify`

Public · rate limited `otp_verify`

`{ "phone", "code", "name"?, "device"? }` → session. **201** with
`"created": true` when the number is new — sign-in and registration are one
request, because a number that receives a code is proof of control either way.

### `POST /auth/phone/link`

User · rate limited `otp_verify`. `{ "phone", "code" }` → `{ "user": … }`.

---

## Social sign-in

Google, Apple, Facebook, GitHub. The **provider's token never leaves the
server**; the app only ever holds a single-use AURIX grant.

```
app  → POST /auth/oauth/google/start        → { authorizationUrl }
app  → opens it in a system browser         → Google
                                            → GET|POST …/callback  (server)
                                               code → tokens → profile → account
     ← 302 aurix://login-callback?code=…
app  → POST /auth/oauth/exchange { code }   → session, or a link challenge
```

### `POST /auth/oauth/{provider}/start`

Optional auth · rate limited `oauth_start`

```jsonc
{ "redirectUri": "aurix://login-callback", "intent": "signIn", "device": "Pixel 8" }
```

→ `{ "authorizationUrl": "https://…", "state": "…", "expiresInSeconds": 600 }`

`redirectUri` must be in `OAUTH_APP_REDIRECTS` exactly. That allow-list is not a
formality: the last hop puts a one-time credential in a URL.

Errors: `provider_unavailable` · `bad_request` (unregistered redirect) ·
`unauthenticated` (link without a session)

### `GET|POST /auth/oauth/{provider}/callback`

The provider's, not yours. Redirects to the app with `?code=` or
`?error=`. Apple **POSTs** this — requesting name and email forces
`response_mode=form_post`, and that body is the only place Apple ever discloses
the user's name.

A callback with no usable `state` renders a dead-end page rather than
redirecting somewhere it has just failed to verify.

### `POST /auth/oauth/exchange`

Public · rate limited `oauth_exchange`. `{ "code", "device"? }`.

Either a **session**, or a **link challenge** when the provider account maps to
an existing AURIX user:

```jsonc
{
  "linkRequired": true,
  "linkToken": "…",
  "provider": "google",
  "providerLabel": "Google",
  "email": "al•••@example.com",
  "hasPassword": true,
  "methods": ["password"],
  "expiresInSeconds": 600
}
```

> The challenge exists because AURIX accounts can be unverified. Auto-linking on
> a matching address would let somebody who registered with *your* address, and
> never confirmed it, receive your Google identity.

---

## Account linking

### `POST /auth/link/code`

Public · rate limited `link`. `{ "linkToken" }` →

```jsonc
{ "ok": true, "message": "OTP sent successfully", "channel": "email",
  "destination": "al•••@example.com", "expiresInSeconds": 300, "resendInSeconds": 30 }
```

For accounts with no password — created by a phone code or another provider —
for which there would otherwise be no way to complete a link.

### `POST /auth/link/confirm`

Public · rate limited `link`

`{ "linkToken", "password"? , "code"?, "device"? }` → session with
`"linked": true`.

Accepts **either** the account password or the code. A wrong password burns an
attempt against the grant, which is destroyed after five — otherwise this would
be an unmetered password oracle for a known address.

### `POST /auth/link/cancel`

Public. `{ "linkToken" }` → **204**. Silent about whether the grant existed.

---

## Profile

All require a bearer token.

| Method | Path | Body | Response |
|---|---|---|---|
| `GET` | `/profile/me` | — | `{ user }` |
| `GET` | `/profile/{uid}` | — | `{ user }` · **403** for anyone else's |
| `POST` | `/profile/ensure` | `{ name?, email? }` | `{ user }` |
| `PATCH` | `/profile/me` | `{ name?, avatarId? }` | `{ user }` |
| `PUT` | `/profile/me/avatar` | `{ avatarId }` | `{ user }` |
| `GET` | `/profile/me/stats` | — | `{ likedTracks, playlists, recentlyPlayed }` |

`/profile/{uid}` is the **only** route that takes a uid from its path. Every
other per-user query derives it from the token — which is what makes reading a
stranger's library a query the client cannot phrase, rather than a rule it might
talk past.

`ensure` only ever *fills gaps*. It will not rename an account whose owner set
something deliberately.

---

## Library

All require a bearer token. The uid is always the caller's.

### `GET /library/liked`

`?limit=` (default 500, max 2000) → `{ "tracks": [ … ] }`, newest first.

### `PUT /library/liked/{trackId}`

Body is a track object → **204**.

Idempotent: liking twice is one row, and re-liking does **not** move the song to
the top of the list.

### `DELETE /library/liked/{trackId}` → **204**

### `GET /library/liked/{trackId}` → `{ "liked": true }`

### `POST /library/liked/among`

`{ "trackIds": [ … ] }` (≤1000) → `{ "likedIds": [ … ] }`. One request for a
screenful rather than one per row.

### `GET /library/recently-played`

`?limit=` (default 50, max 200) →

```jsonc
{ "entries": [ { "id": "…", "title": "…", "playedAt": "…Z", "position": 0 } ] }
```

### `POST /library/recently-played`

`{ "trackId", "track", "position" }` → **204**. History is trimmed to the newest
200 per account after the write.

### `DELETE /library/recently-played` → **204**

---

## Playlists

The caller's own. All require a bearer token.

| Method | Path | Body / Query | Response |
|---|---|---|---|
| `GET` | `/playlists` | — | `{ playlists }` (≤500) |
| `GET` | `/playlists/find` | `?source&sourceId` | `{ playlist \| null }` |
| `GET` | `/playlists/{id}` | — | `{ playlist }` · 404 |
| `GET` | `/playlists/{id}/tracks` | `?limit` | `{ tracks }` in order |
| `POST` | `/playlists` | `{ name, description?, coverUrl?, source?, sourceId?, sourceUrl? }` | **201** `{ id }` |
| `PATCH` | `/playlists/{id}` | `{ name, description? }` | **204** |
| `PUT` | `/playlists/{id}/cover` | `{ coverUrl }` | **204** |
| `POST` | `/playlists/{id}/synced` | `{ name?, coverUrl? }` | **204** |
| `DELETE` | `/playlists/{id}` | — | **204** |
| `POST` | `/playlists/{id}/tracks` | `{ trackId, track }` | **204** — appends |
| `POST` | `/playlists/{id}/tracks/bulk` | `{ tracks: [ … ] }` | `{ added }` — appends |
| `PUT` | `/playlists/{id}/tracks` | `{ tracks: [ … ] }` | `{ written }` — replaces order |
| `DELETE` | `/playlists/{id}/tracks/{trackId}` | — | **204** |
| `POST` | `/playlists/{id}/tracks/remove` | `{ trackIds: [ … ] }` | `{ removed }` |
| `POST` | `/playlists/{id}/reorder` | see below | see below |

`POST` **appends** — position assigned after the current last, and set only on
insert, so re-adding a track already present does not move it. `PUT` **replaces
the order**, assigning positions from the list index: what a re-sync wants.

Track lists cap at 5000 per request.

### `POST /playlists/{id}/reorder`

```jsonc
{ "orderedTrackIds": ["a", "b", "c"], "from": 0, "to": 2 }
```

```jsonc
{ "rebalanced": false, "position": 3072 }   // one row changed
{ "rebalanced": true }                      // the whole list was renumbered
```

`position` is a **double**, so a drag in a 2,000-track playlist is normally one
write — the new position is the midpoint of its new neighbours. Repeatedly
dropping into the same gap halves it, and eventually two positions are too close
for a double to separate; the list is then renumbered onto clean spacing.

**Branch on `rebalanced`.** `true` means every cached position is stale and you
should refetch. `false` means patch the one row you have.

---

## Shared playlists

The catalogue users contribute to by importing. Readable by every signed-in
user — that is what "shared" means. All require a bearer token.

| Method | Path | Body / Query | Response |
|---|---|---|---|
| `GET` | `/shared-playlists/search` | `?q&limit` | `{ playlists }` ranked |
| `GET` | `/shared-playlists/find` | `?source&sourceId&sourceUrl` | `{ playlist \| null }` |
| `GET` | `/shared-playlists/imported-by/{uid}` | — | `{ playlists }` |
| `GET` | `/shared-playlists/{id}` | — | `{ playlist \| null }` |
| `GET` | `/shared-playlists/{id}/tracks` | `?limit` | `{ tracks }` |
| `POST` | `/shared-playlists` | `{ id, source, sourceId, name?, … }` | **201** `{ id, created }` |
| `PUT` | `/shared-playlists/{id}/tracks` | `{ tracks }` | `{ written }` |
| `POST` | `/shared-playlists/{id}/tracks/remove` | `{ trackIds }` | `{ removed }` |
| `POST` | `/shared-playlists/{id}/synced` | `{ name?, coverUrl? }` | **204** |
| `DELETE` | `/shared-playlists/{id}` | — | **204** · **403** |

`id` is **client-derived** from the source and its id, so two people importing
the same playlist land on the same document. Only the first importer may change
its name or cover, and only they may delete it — otherwise the title everyone
sees would be decided by whoever synced most recently.

`importedByUserId` is **provenance, not ownership**, everywhere except `DELETE`.

---

## Catalogue

The shared song catalogue. All require a bearer token.

Note the song shape differs from a track: `artists` is an **array**, and the
duration field is `duration`.

### `GET /catalog/songs/search`

`?q&limit` (default 20, max 100) → `{ "songs": [ … ] }`

One indexed lookup on the longest word of the query — the most selective — then
the remaining words are applied over the result page.

### `POST /catalog/songs/batch`

`{ "ids": [ … ] }` (≤2000) → `{ "songs": { "<id>": { … } } }`

**A map keyed by id, not an array.** Ids that do not exist are absent rather
than null.

### `GET /catalog/songs/{id}` → `{ "song": … | null }`

### `POST /catalog/songs`

`{ "songs": [ … ] }` (≤2000) → `{ "written", "created", "updated" }`

> **A merge, not an overwrite.** The same song arrives from different sources
> carrying different metadata — a Spotify import knows the album, a YouTube one
> often does not. Empty fields are filled; **populated fields are never
> replaced**. Repeated imports therefore improve the catalogue monotonically
> rather than churning it.

---

## Appearance

### `GET /theme`

Public — read before anyone signs in, so the login screen can style itself.
`Cache-Control: public, max-age=60`.

```jsonc
{ "theme": {
  "version": 7,
  "fontFamily": "Manrope",
  "fontAssetId": null,
  "typography": { "scale": 1, "letterSpacing": 0, "weightRegular": 400, … },
  "colors": { "dark": { "primary": "#FFFFFF", … }, "light": { … } },
  "musicPlayer": { "mini": "theme1", "large": "theme1", … },
  "appLogo": "/api/v1/assets/…",
  "appIcon": null,
  "primaryColor": "#FFFFFF"   // the dark colourway, mirrored flat
} }
```

`updatedBy` is omitted for anonymous callers.

### `GET /theme/version` → `{ "version", "updatedAt" }`

A few bytes instead of the whole palette, for the poll every install makes.
`version` is the cache key and is bumped on every write.

### `GET /theme/options` → `{ "fonts", "players", "colorRoles" }`

### Administrator only

| Method | Path | Body | Response |
|---|---|---|---|
| `PUT` | `/theme` | theme patch | `{ theme }` |
| `POST` | `/theme/reset` | — | `{ theme }` |
| `POST` | `/theme/logo` | multipart `file` | **201** `{ asset, theme }` |
| `DELETE` | `/theme/logo` | — | `{ theme }` |
| `POST` | `/theme/icon` | multipart `file` | **201** `{ asset, theme }` |
| `DELETE` | `/theme/icon` | — | `{ theme }` |
| `POST` | `/theme/fonts` | multipart `file`, `family`, `apply?` | **201** `{ asset, family, theme }` |
| `GET` | `/theme/fonts` | — | `{ fonts }` |
| `DELETE` | `/theme/fonts/{id}` | — | **204** |

The patch accepts both the nested `colors.dark.primary` form and the flat
`primaryColor` form; flat keys apply to the dark colourway. Every value is
bounded — `scale` 0.8–1.4, weights 100–900, colours `#RRGGBB` or `#AARRGGBB`.

**Uploads are typed by their magic bytes**, never by filename or
`Content-Type`. Images: PNG, JPEG, WebP, GIF. **SVG is refused** — it can carry
script, and serving one from this origin is stored XSS against the admin portal.
Fonts: TTF, OTF, WOFF, WOFF2.

Limits default to 2 MB images and 3.5 MB fonts. The font cap sits below Vercel's
4.5 MB request limit so an oversized file fails as `payload_too_large` rather
than as a platform error.

### `GET /assets/{id}`

Public. Streams the file with the stored content type, `nosniff`, an ETag, and
`Cache-Control: immutable` — safe because the id changes when the file does.

---

## Administration

Administrator only. `admin_only` otherwise.

> These endpoints are called by the admin portal and by **no Dart code**.
> Administrator status is re-read from the database on every request, so a
> revoked administrator loses access immediately rather than at their next token
> refresh.

### `GET /admin/stats`

```jsonc
{ "users": 128, "admins": 2, "likedTracks": 4210,
  "playlists": 96, "sharedPlaylists": 41, "songs": 8800 }
```

### `GET /admin/users`

`?q&limit` (default 50, max 200) → `{ "users": [ … ] }`

`q` matches the **start** of an email or name. Anchored and escaped: an
unanchored regex could not use the index, and an unescaped one is a
catastrophic-backtracking denial of service.

### `POST /admin/users/{uid}/admin`

`{ "isAdmin": true }` → `{ "user": … }`

Refuses to demote the **last** administrator with `bad_request`. Without that,
a deployment can lock itself out of its own configuration with one click.

---

## Notes for client authors

**Timestamps** are ISO-8601 strings. `Json.timestamp` on the Dart side parses
them.

**204 has no body.** Do not parse one.

**Ids the client derives** — `TrackKey`, `SongKey`, `PlaylistKey` — must match
`^[A-Za-z0-9._~-]+$` and be ≤220 characters. They are how the same song
imported by two people becomes one row.

**Search normalisation is duplicated** between `mobile/lib/data/models/song_key.dart`
and `web/src/server/utils/search.ts`, deliberately: the client writes the tokens
and the server queries them, so the two must fold accents and strip packaging
identically. Change one, change the other.

**Refresh once, not per request.** Several requests finding the token expired at
the same moment should share one refresh — `AurixApiClient` does this.
