# AURIX — Express → Next.js Migration Map

**Status:** Phase 2 output. Nothing has been migrated yet. This document is the
contract the migration is executed against and verified against.

**Source of truth:** `server/src/` at commit `aed111c`. Every shape below was
read out of the handler that produces it, not inferred from a model or a doc.

---

## 0. Decisions this map assumes

These were recommended in the Phase 1 audit and are adopted here. Each is
reversible while this document is still the only artefact.

| # | Decision | Rationale |
|---|---|---|
| D1 | Flutter moves to `mobile/`; Next.js takes `web/` | Resolves the `web/` collision — Flutter's `web/` travels with it into `mobile/web/` |
| D2 | **Response envelope preserved verbatim** | `{success,message,data}` would require rewriting all 3,524 lines of `lib/data/services/api/*`. See §2 |
| D3 | **Prefix stays `/api/v1`** | `AurixEndpoints.prefix` pins it; keeping it means the Flutter diff is one env value |
| D4 | Rate limiting moves to a MongoDB-backed store | No new infrastructure; the `otpSends` collection already proves the pattern |
| D5 | Admin portal ships only modules backed by real collections | There are no `albums`, `artists` or `genres` collections. See §7 |

---

## 1. Structural move

```
BEFORE                          AFTER
Music/                          AURIX/
├── lib/ android/ ios/          ├── mobile/          ← git mv, unchanged content
│   assets/ test/ web/          │   ├── lib/ android/ ios/ assets/ test/ web/
│   integration_test/           │   └── pubspec.yaml
│   pubspec.yaml                │
├── server/            ────────▶├── web/             ← Next.js: API + admin portal
│                               ├── server-backup/   ← frozen copy of server/ (Step 17)
├── docs/                       ├── docs/
└── README.md                   └── README.md
```

`server/` stays in place and runnable until Phase 15 signs off. `server-backup/`
is the frozen reference copy.

---

## 2. The response envelope — DO NOT CHANGE

The existing API does **not** use `{success, message, data}`. The Dart client is
written against what exists, and `AurixApiClient._send` + `AurixApiException`
depend on it.

### Success

Bare objects, keyed by resource. No wrapper.

```jsonc
{ "tracks": [...] }              // collection reads
{ "playlist": {...} }            // single reads (null when absent, not 404)
{ "user": {...} }                // any route returning an account
201 { "id": "aB3xY..." }         // creates
204 (empty body)                 // writes that return nothing
```

### Error

```jsonc
{ "error": { "code": "invalid_credentials",
             "message": "That email and password do not match.",
             "details": [ { "path": "email", "message": "..." } ] } }
```

`details` appears only on Zod validation failures. In non-production a 500 also
carries `error.debug`.

### The full error-code vocabulary

`api_auth_service.dart` switches on these strings. **Renaming one silently
degrades a specific user-facing message into a generic one.**

| Code | HTTP | Code | HTTP |
|---|---|---|---|
| `bad_request` | 400 | `invalid_code` | 401 |
| `weak_password` | 400 | `code_expired` | 401 |
| `invalid_email` | 400 | `forbidden` | 403 |
| `invalid_phone` | 400 | `admin_only` | 403 |
| `invalid_auth_state` | 400 | `not_found` | 404 |
| `invalid_credentials` | 401 | `conflict` | 409 |
| `unauthenticated` | 401 | `email_in_use` | 409 |
| `token_expired` | 401 | `phone_in_use` | 409 |
| `rate_limited` | 429 | `identity_in_use` | 409 |
| `payload_too_large` | 413 | `last_sign_in_method` | 409 |
| `unsupported_media_type` | 415 | `otp_unavailable` | 503 |
| `internal` | 500 | `provider_unavailable` | 503 |
| | | `unavailable` | 503 |

### The session payload

Produced by `services/session.js` and by **nothing else**. Six sign-in doors,
plus refresh and link-confirm, all return exactly this. `ApiAuthService._storeSession`
is the single reader.

```jsonc
{
  "user":         { /* accountView — see §3 */ },
  "accessToken":  "eyJ...",           // JWT, 30m
  "refreshToken": "…",                // opaque, 60d
  "expiresAt":    "2026-10-27T…Z",    // ISO-8601, refresh-token expiry
  // optional extras, per door:
  "device": "…", "provider": "google", "created": true, "linked": true
}
```

---

## 3. Shared object shapes

### `accountView(user)` — `services/users.js:46`

```jsonc
{
  "uid": "…", "name": "…", "email": "…", "phone": "…",
  "avatarId": "avatar_01",
  "emailVerified": false, "phoneVerified": false,
  "emailIsPrivateRelay": false,
  "isAdmin": false,
  "providers": ["password", "google"],
  "createdAt": "…Z", "updatedAt": "…Z"
}
```

`passwordHash` is never present. `providers` is resolved from the `identities`
collection.

### `S.track` — the validated track body (`middleware/validate.js`)

`.strip()`, not passthrough: unknown fields are **dropped, not stored**.

| Field | Type | Default |
|---|---|---|
| `title` | string ≤500 | `"Unknown track"` |
| `artist` | string ≤500 | `""` |
| `album` | string ≤500 | `""` |
| `durationMs` | int 0…86 400 000 | `0` |
| `artworkUrl` | string ≤2048 | `""` |
| `explicit` | bool | `false` |
| `source` | string ≤32 | `"aurix"` |
| `sourceId` `spotifyId` `youtubeVideoId` `previewUrl` | nullish | — |

### `trackOut(doc)`

Strips `_id`, `uid`, `trackId`, `playlistId`, `position`; emits `id` (= `trackId`)
and ISO `createdAt`. **The storage keys never reach the client.**

### Other field schemas

`email` ≤320 lowercased · `password` **min 8** (must match `AppConstants.minPasswordLength`)
· `displayName` 1–80 · `uid` ≤64 · `docId` ≤220 matching `^[A-Za-z0-9._~-]+$`
· `url` ≤2048.

---

## 4. Endpoint migration map

**Legend** — Auth: `—` public · `U` bearer required · `U?` optional bearer ·
`A` admin (`requireAuth` + `requireAdmin`, re-reads `users.isAdmin`) ·
`T` token in body · `P` provider callback.

All new paths are `web/app/api/v1/…/route.ts`. **Every path is unchanged.**

### 4.1 Auth — `auth.routes.js` → `api/v1/auth/`

| M | Path | A | Request | Response | Flutter caller |
|---|---|---|---|---|---|
| GET | `/auth/methods` | — | — | `{methods:[…]}` | `ApiAuthService` :550 |
| DELETE | `/auth/methods/:provider` | U | — | `{user}` | `unlink()` :770 |
| POST | `/auth/register` | — | `{email,password,name,device?}` | **201** session | `register()` :313 |
| POST | `/auth/login` | — | `{email,password,device?}` | session | `signIn()` :320 |
| POST | `/auth/refresh` | — | `{refreshToken}` | session | `AurixApiClient._refresh` |
| POST | `/auth/logout` | — | `{refreshToken?}` | **204** | `signOut()` :375 |
| GET | `/auth/me` | U | — | `{user}` | `reload()` :494 |
| PATCH | `/auth/me` | U | `{name?,avatarId?}` | `{user}` | `updateDisplayName()` :507 |
| DELETE | `/auth/me` | U | `{password?}` | **204** | `deleteAccount()` :524 |
| POST | `/auth/password/change` | U | `{currentPassword?,newPassword}` | session | `updatePassword()` :435 |
| POST | `/auth/password/forgot` | — | `{email}` | `{ok,message,devToken?}` | `sendPasswordResetEmail()` :386 |
| POST | `/auth/password/reset` | T | `{token,password}` | `{ok:true}` | `resetPassword()` :410 |
| POST | `/auth/email/verify/send` | U | — | `{ok,alreadyVerified?,devToken?}` | `sendEmailVerification()` :460 |
| POST | `/auth/email/verify` | T | `{token}` | `{ok,user}` | `verifyEmail()` :476 |

**Behaviour that must survive the port, verbatim:**

- `login` runs bcrypt **even when the account does not exist**
  (`verifyPassword(password, user?.passwordHash ?? '')`) and returns one error
  for both cases. Dropping either half restores an address-enumeration oracle —
  the timing one is the easy one to lose.
- `password/forgot` returns the identical body whether or not the account exists.
- `password/change` and `DELETE /me` treat `currentPassword`/`password` as
  optional **only when the account has no password hash** (social/phone
  accounts). Where a hash exists it is required and checked.
- `password/change` and `password/reset` call `revokeAllRefreshTokens` — every
  other device signs out. The caller survives because the response carries a
  fresh pair.
- `register` fires the verification email **fire-and-forget**; a mail failure
  must not fail the registration.
- `DELETE /me` deletes 7 collections but deliberately **not**
  `globalPlaylists`/`globalPlaylistTracks` — a shared playlist is other users'
  data. It *does* delete `identities`, or the unique `(provider,subject)` index
  would block that person ever signing up again.

### 4.2 Phone — `auth.phone.routes.js` → `api/v1/auth/phone/`

| M | Path | A | Request | Response | Flutter caller |
|---|---|---|---|---|---|
| POST | `/auth/phone/start` | U? | `{phone,intent:signIn\|link}` | `{ok,message,phone(masked),expiresInSeconds,resendInSeconds}` | `startPhoneSignIn()` :579 |
| POST | `/auth/phone/verify` | — | `{phone,code,name?,device?}` | session (**201** + `created:true` if new) | `verifyPhoneCode()` :603 |
| POST | `/auth/phone/link` | U | `{phone,code}` | `{user}` | `linkPhone()` :624 |

Gated on `env.phoneSignInEnabled`; unconfigured ⇒ `otp_unavailable` (503)
**before a code is generated**. The code is never in a response, log or error.
`OTP_DEV_DELIVERY=file` is dropped in the port.

### 4.3 OAuth — `auth.oauth.routes.js` → `api/v1/auth/oauth/`

Providers: `google` `apple` `facebook` `github`.

| M | Path | A | Request | Response | Flutter caller |
|---|---|---|---|---|---|
| POST | `/auth/oauth/:provider/start` | U? | `{redirectUri,intent,device?}` | `{…flow}` | `_browserFlow()` :681 |
| GET | `/auth/oauth/:provider/callback` | P | query | **302** to `redirectUri?code=…&state=…` | browser |
| POST | `/auth/oauth/:provider/callback` | P | form-urlencoded | **302** | browser (**Apple only**) |
| POST | `/auth/oauth/exchange` | — | `{code,device?}` | session **or** link challenge | `_browserFlow()` :696 |

Link challenge (when the provider account maps to an existing AURIX user):

```jsonc
{ "linkRequired": true, "linkToken": "…", "provider": "google",
  "providerLabel": "Google", "email": "a•••@e•••.com",
  "hasPassword": true, "methods": [...], "expiresInSeconds": 600 }
```

**Port notes.** The callback is the only route that returns HTML/redirects
rather than JSON — a dead-end page on a consumed `state`, a 302 otherwise.
`state` and `grant` live in `authStates`/`authGrants` in Mongo, so they are
already serverless-safe. Apple form-POSTs its callback (a consequence of
requesting name+email scopes) and the user's **name arrives exactly once, on
first authorization, and never again** — `provider.profile()` reads it out of
`req.body`, so the Next.js handler must parse the form body and pass it through
identically.

### 4.4 Account linking — `auth.link.routes.js` → `api/v1/auth/link/`

| M | Path | A | Request | Response | Flutter caller |
|---|---|---|---|---|---|
| POST | `/auth/link/code` | — | `{linkToken}` | `{ok,message,channel,destination(masked),expiresInSeconds,resendInSeconds}` | `sendAccountLinkCode()` :717 |
| POST | `/auth/link/confirm` | — | `{linkToken,password?,code?,device?}` | session + `linked:true` | `confirmAccountLink()` :739 |
| POST | `/auth/link/cancel` | — | `{linkToken}` | **204** | `cancelAccountLink()` :759 |

`confirm` accepts *either* the account password *or* the emailed/SMS code. A
wrong password calls `countGrantAttempt` — the grant is burned after N attempts,
so this is not a password oracle.

### 4.5 Profile — `profile.routes.js` → `api/v1/profile/` · all `U`

| M | Path | Request | Response | Flutter caller |
|---|---|---|---|---|
| GET | `/profile/me` | — | `{user}` | `ApiProfileService` |
| GET | `/profile/:uid` | — | `{user}` | `read()` :57 |
| POST | `/profile/ensure` | `{name?,email?}` | `{user}` | `ensureProfile()` :87 |
| PATCH | `/profile/me` | `{name?,avatarId?}` | `{user}` | `update()` :108 |
| PUT | `/profile/me/avatar` | `{avatarId}` | `{user}` | `setAvatar()` :120 |
| GET | `/profile/me/stats` | — | `{likedTracks,playlists,recentlyPlayed}` | `stats()` :128 |

`GET /profile/:uid` is guarded by `requireSelf('uid')` — a 403 for anyone else's
uid. This is the **only** route taking a uid from the path; every other per-user
query derives it from `req.user.uid`.

### 4.6 Library — `library.routes.js` → `api/v1/library/` · all `U`

| M | Path | Request | Response | Flutter caller |
|---|---|---|---|---|
| GET | `/library/liked` | `?limit` (500/2000) | `{tracks:[…]}` newest-first | `ApiLibraryService` :60 |
| PUT | `/library/liked/:trackId` | `S.track` | **204** | `like()` :74 |
| DELETE | `/library/liked/:trackId` | — | **204** | `unlike()` :81 |
| GET | `/library/liked/:trackId` | — | `{liked:bool}` | `isLiked()` :86 |
| POST | `/library/liked/among` | `{trackIds[≤1000]}` | `{likedIds:[…]}` | :99 |
| GET | `/library/recently-played` | `?limit` (50/200) | `{entries:[{…,playedAt,position}]}` | :117 |
| POST | `/library/recently-played` | `{trackId,track,position}` | **204** | `recordPlay()` :157 |
| DELETE | `/library/recently-played` | — | **204** | `clearHistory()` :174 |

`PUT /liked/:trackId` is an **upsert on `(uid,trackId)` with
`$setOnInsert:{createdAt}`** — liking is idempotent *and* re-liking must not
move the song to the top. Both halves are load-bearing. Backed by a unique index.

History is trimmed to **200** rows per user asynchronously after each write; a
trim failure is logged, never surfaced. On Vercel this fire-and-forget must be
**awaited** or moved to `waitUntil()`, or the function may be frozen before it
runs.

### 4.7 User playlists — `playlists.routes.js` → `api/v1/playlists/` · all `U`

| M | Path | Request | Response | Flutter caller |
|---|---|---|---|---|
| GET | `/playlists` | — | `{playlists:[…]}` (≤500, `updatedAt` desc) | :95 |
| GET | `/playlists/find` | `?source&sourceId` | `{playlist\|null}` | `findOwnBySource()` :155 |
| GET | `/playlists/:id` | — | `{playlist}` / 404 | `readPlaylist()` :101 |
| GET | `/playlists/:id/tracks` | `?limit` (2000/5000) | `{tracks}` by `position` | :112 |
| POST | `/playlists` | `{name,description,coverUrl,source,sourceId?,sourceUrl?}` | **201** `{id}` | `create()` :178 |
| PATCH | `/playlists/:id` | `{name,description?}` | **204** | `rename()` :202 |
| POST | `/playlists/:id/synced` | `{name?,coverUrl?}` | **204** | `markSynced()` :227 |
| PUT | `/playlists/:id/cover` | `{coverUrl}` | **204** | `setCover()` :243 |
| DELETE | `/playlists/:id` | — | **204** | `delete()` :258 |
| POST | `/playlists/:id/tracks` | `{trackId,track}` | **204** | `addTrack()` :272 |
| POST | `/playlists/:id/tracks/bulk` | `{tracks[≤5000]}` | `{added}` | `addTracks()` :286 |
| PUT | `/playlists/:id/tracks` | `{tracks[≤5000]}` | `{written}` | `writeTracksInOrder()` :312 |
| DELETE | `/playlists/:id/tracks/:trackId` | — | **204** | `removeTrack()` :325 |
| POST | `/playlists/:id/tracks/remove` | `{trackIds[≤5000]}` | `{removed}` | `removeTracks()` :340 |
| POST | `/playlists/:id/reorder` | `{orderedTrackIds,from,to}` | `{rebalanced,position?}` | `reorder()` :366 |

Ids: `crypto.randomBytes(15).toString('base64url').slice(0,20)`.

**Reorder is fractional-position ordering**, not an index rewrite:
`positionBetween(before, after)` finds a gap; when floats run out of precision it
returns `null` and the whole playlist is rebalanced, answering
`{rebalanced:true}`. The Dart side branches on that flag. This algorithm must
port exactly — `services/playlists.js` is 213 lines of pure logic with no
Express dependency, so it is a straight TS copy.

`recount()` after every track mutation is fire-and-forget → same `waitUntil()`
caveat as §4.6.

### 4.8 Shared playlists — `sharedPlaylists.routes.js` → `api/v1/shared-playlists/` · all `U`

| M | Path | Request | Response | Flutter caller |
|---|---|---|---|---|
| GET | `/shared-playlists/search` | `?q&limit` (20/100) | `{playlists}` ranked | :69 |
| GET | `/shared-playlists/find` | `?source&sourceId&sourceUrl` | `{playlist\|null}` | `findBySource()` :147 |
| GET | `/shared-playlists/imported-by/:uid` | — | `{playlists}` (≤500) | :127 |
| GET | `/shared-playlists/:id` | — | `{playlist\|null}` | `read()` :107 |
| GET | `/shared-playlists/:id/tracks` | `?limit` | `{tracks}` | :122 |
| POST | `/shared-playlists` | `{id,source,sourceId,name,description,coverUrl,sourceUrl?,importedBy}` | **201** `{id,created}` | `upsert()` :199 |
| PUT | `/shared-playlists/:id/tracks` | `{tracks[≤5000]}` | `{written}` | :235 |
| POST | `/shared-playlists/:id/tracks/remove` | `{trackIds}` | `{removed}` | :259 |
| POST | `/shared-playlists/:id/synced` | `{name?,coverUrl?}` | **204** | `markSynced()` :273 |
| DELETE | `/shared-playlists/:id` | — | **204** / 403 | `delete()` :290 |

This is a **shared** catalogue: `_id` is client-derived, so a second importer of
the same playlist hits the existing row. Only `importedByUserId` may mutate
name/cover, and only they may `DELETE` (403 `forbidden` otherwise).

Search is token-index + residual-word filtering with `SEARCH_FANOUT = 4`, then
ranked exact → prefix → other, tiebroken on `trackCount`. `utils/search.js`
(212 lines, pure) ports directly.

### 4.9 Catalog — `catalog.routes.js` → `api/v1/catalog/` · all `U`

| M | Path | Request | Response | Flutter caller |
|---|---|---|---|---|
| GET | `/catalog/songs/search` | `?q&limit` (20/100) | `{songs:[…]}` | :104 |
| POST | `/catalog/songs/batch` | `{ids[≤2000]}` | `{songs:{id:song}}` **map, not array** | :70 |
| GET | `/catalog/songs/:id` | — | `{song\|null}` | `song()` :45 |
| POST | `/catalog/songs` | `{songs[≤2000]}` | `{written,created,updated}` | `upsertAll()` :147 |

`songOut` maps `_id → id`. Note the song schema differs from `S.track`:
`artists` is an **array**, and the duration field is `duration`, not
`durationMs`.

`POST /catalog/songs` is a **merge-only enricher**, not an overwrite.
`mergeDelta` fills empty fields on existing rows and never replaces populated
ones; `preferRicher` dedupes the incoming batch by scoring album+duration+artwork.
`searchTokens` are recomputed only when `album` changes. Written as one unordered
`bulkWrite`. This is the one write path where a naive "just upsert" port would
silently degrade catalogue data.

### 4.10 Theme & assets — `theme.routes.js`, `assets.routes.js`

| M | Path | A | Request | Response | Flutter caller |
|---|---|---|---|---|---|
| GET | `/theme` | U? | — | `{theme}`, `Cache-Control: 60` | `fetch()` :45 |
| GET | `/theme/version` | — | — | `{version,updatedAt}` | `version()` :82 |
| GET | `/theme/options` | — | — | `{fonts,players,colorRoles}` | `options()` :92 |
| PUT | `/theme` | **A** | theme patch | `{theme}` | `save()` :110 |
| POST | `/theme/reset` | **A** | — | `{theme}` | `reset()` :127 |
| POST | `/theme/logo` | **A** | multipart `file` | **201** `{asset,theme}` | `uploadLogo()` :131 |
| DELETE | `/theme/logo` | **A** | — | `{theme}` | `clearLogo()` :135 |
| POST | `/theme/icon` | **A** | multipart `file` | **201** `{asset,theme}` | `uploadIcon()` :139 |
| DELETE | `/theme/icon` | **A** | — | `{theme}` | `clearIcon()` :143 |
| POST | `/theme/fonts` | **A** | multipart `file` + `family` + `apply` | **201** `{asset,family,theme}` | `uploadFont()` :153 |
| GET | `/theme/fonts` | **A** | — | `{fonts:[…]}` | *(admin panel only)* |
| DELETE | `/theme/fonts/:id` | **A** | — | **204** | *(admin panel only)* |
| GET | `/assets/:id` | — | — | binary stream, 304 on ETag | `<img>` / font loader |

`GET /theme` is `optionalAuth` and strips `updatedBy` for anonymous callers —
the login screen must be able to style itself before anyone has signed in.

**Uploads.** Content type is decided by **magic bytes**, never by the filename or
`Content-Type` header; the stored type is what the server decided, served back
with `X-Content-Type-Options: nosniff`. **SVG is deliberately rejected** for
logos — it is a scriptable document and serving one from the API origin is
stored XSS against the admin panel. All of this must survive the port unchanged.

`GET /assets/:id` streams from GridFS with `immutable` caching and ETag/304. In
Next.js this becomes a `ReadableStream` response on the Node runtime.

### 4.11 Admin — `admin.routes.js` → `api/v1/admin/` · all `A`

| M | Path | Request | Response | Flutter caller |
|---|---|---|---|---|
| GET | `/admin/stats` | — | `{users,admins,likedTracks,playlists,sharedPlaylists,songs}` | **none** |
| GET | `/admin/users` | `?q&limit` (50/200) | `{users:[accountView]}` | **none** |
| POST | `/admin/users/:uid/admin` | `{isAdmin:bool}` | `{user}` | **none** |

> **Finding.** `adminStats`, `adminUsers` and `adminUserRole` are declared in
> `aurix_endpoints.dart` but called from **zero** Dart files. They exist purely
> for the static admin panel. The admin surface can therefore be extended freely
> in Phase 7 with no risk to the mobile app.

`GET /admin/users` anchors and escapes the search regex — unescaped user input
in `$regex` is a catastrophic-backtracking DoS, and unanchored cannot use the
index. `POST .../admin` refuses to demote the **last** administrator.

### 4.12 Health

| M | Path | Response |
|---|---|---|
| GET | `/health` | `{ok,service,db,uptime}` · 200 / **503** when Mongo is down |

Outside `/api/v1` by design. `uptime` is meaningless on Vercel and will be
dropped or replaced with the deployment id.

---

## 5. Server modules → Next.js

### Straight TypeScript copies (no Express dependency) — ~3,000 lines

`services/{users,session,tokens,identities,otp,phone,sms,mailer,theme,playlists,uploads}.js`,
`services/oauth/{flow,providers}.js`, `utils/{search,errors,logger}.js`,
`db/collections.js` → `web/src/server/…`. Only `import`/type annotations change.

### Genuine conversions

| Express | Next.js | Note |
|---|---|---|
| `app.js` `createApp()` | `next.config.ts` headers + `middleware.ts` | helmet CSP → header config; CORS → per-route/middleware |
| `index.js` boot + `listen` | **deleted** | see §6 |
| `middleware/auth.js` | `withAuth()` / `withAdmin()` / `withSelf()` HOFs | `(req,res,next)` → `(handler) => (req, ctx)` |
| `middleware/validate.js` | `withValidation()` / inline Zod parse | Express 5's read-only `req.query` workaround disappears |
| `middleware/error.js` | `toErrorResponse()` in a shared wrapper | same mapping, incl. Mongo `11000` → 409 |
| `db/mongo.js` | lazy `await getDb()` | **the key change** — see §6 |
| `routes/*.js` (2,400 lines) | `app/api/v1/**/route.ts` | thin handlers; logic already in services |
| `public/admin/*` (1,200 lines) | `app/admin/**` React | reimplementation, see §7 |
| `test/*.test.js` (node:test) | Vitest | plus new contract tests |

### Express → Route Handler idioms

| Express | Next.js |
|---|---|
| `req.body` | `await req.json()` |
| `req.query.x` | `new URL(req.url).searchParams.get('x')` |
| `req.params.id` | `ctx.params.id` (**awaited** in Next 15) |
| `req.get('authorization')` | `req.headers.get('authorization')` |
| `res.json(x)` | `Response.json(x)` |
| `res.status(204).end()` | `new Response(null,{status:204})` |
| `res.redirect(url)` | `Response.redirect(url, 302)` |
| `multer.single('file')` | `(await req.formData()).get('file')` |
| `stream.pipe(res)` | `new Response(stream as ReadableStream)` |

---

## 6. Vercel-compatibility work

| # | Issue | Fix |
|---|---|---|
| V1 | `getDb()` **throws** when `connect()` hasn't run; `index.js` awaits connect + `ensureIndexes` + theme seed before listening. Serverless has no boot phase. | Every accessor becomes `async` and awaits the memoized `connect()`. The memo already handles warm-start re-entry — the comment in `mongo.js` anticipates it. `ensureIndexes` moves to `npm run indexes` (deploy step). Theme seeding becomes lazy inside `readTheme()`. |
| V2 | `app.listen()`, SIGTERM/SIGINT handlers, `close()` | Deleted. **Never** call `client.close()` between invocations. |
| V3 | 7 × `express-rate-limit` with the **default in-memory store** — guarding login, register, reset, OTP and OAuth. Per-instance counters on Vercel multiply the effective limit by instance count. | Mongo-backed limiter keyed `(route, ip)` with a TTL index, mirroring `otpSends`. **Security-relevant — must not ship without it.** |
| V4 | Vercel caps request bodies at **4.5 MB**; `MAX_FONT_BYTES` is 4 MB, so a legitimate font + multipart overhead can exceed it. | Lower the font cap to 3.5 MB and surface `payload_too_large` cleanly. GridFS *reads* stream fine and are unaffected. |
| V5 | `OTP_DEV_DELIVERY=file` writes `otp-dev.log` to disk | Removed. Already forced off in production. |
| V6 | Fire-and-forget `trim()`, `recount()`, verification mail | `waitUntil()` or await — the function can freeze before a detached promise runs. |
| V7 | `dns.setServers()` / `DNS_SERVERS` | Dropped; not applicable. |
| V8 | Cold start = SRV lookup + TLS to Atlas, `serverSelectionTimeoutMS: 8000` | Co-locate the Vercel region with the Atlas region. |
| V9 | `app.set('trust proxy', 1)` | Vercel sets `x-forwarded-for`; the new limiter reads it directly. |
| V10 | helmet CSP written for the static admin panel | Moves to `next.config.ts`; must be widened for Next's runtime while keeping `frame-ancestors: none` and `object-src: none`. |
| V11 | `express.static('/admin')` + `/` redirect | Replaced by App Router pages. |
| V12 | Runtime | **`export const runtime = 'nodejs'` on every route** — the Mongo driver cannot run on Edge. |

---

## 7. Admin portal scope

Derived from collections that actually exist. **There are no `albums`, `artists`
or `genres` collections**, so those modules from the original brief are not
implementable against current data and are excluded (open question O5).

| Module | Route | Backed by | Endpoints |
|---|---|---|---|
| Login | `/admin/login` | — | `POST /auth/login` then reject `isAdmin !== true` |
| Dashboard | `/admin` | 6 counts | `GET /admin/stats` |
| Users | `/admin/users` | `users`, `identities` | `GET /admin/users`, `POST /admin/users/:uid/admin` |
| Songs | `/admin/songs` | `catalogSongs` | `GET /catalog/songs/search`, `GET /catalog/songs/:id` |
| Playlists | `/admin/playlists` | `globalPlaylists` | `GET /shared-playlists/search`, `/:id`, `/:id/tracks` |
| Appearance | `/admin/theme` | `appConfig`, GridFS | all of `/theme/*` |
| Uploads | `/admin/uploads` | GridFS `brandAssets` | `GET /theme/fonts`, `DELETE /theme/fonts/:id` |

Admin auth reuses the existing JWT — there is no second identity system, and
inventing one would mean a second set of credentials to leak. `requireAdmin`
re-reads `users.isAdmin` from the database on every admin request rather than
trusting the token claim, so a revoked admin loses access immediately. That
property must be preserved.

**Read-only in Phase 7.** Songs and Playlists are listed and inspected, not
edited: no delete endpoint exists for `catalogSongs`, and `DELETE
/shared-playlists/:id` is restricted to the importing user by design. Adding
admin mutation is a **new feature**, not a migration, and is out of scope for
this document.

---

## 8. Flutter changes

**Total required change: one configuration value.**

```diff
- AURIX_API_BASE_URL=http://localhost:4000
+ AURIX_API_BASE_URL=https://aurix-api.vercel.app
```

`AurixEndpoints` supplies every path and needs no edit. `Env.apiBaseUrl` already
strips a trailing `/api/v1` if the full API root is pasted in. Per-platform
overrides `AURIX_API_BASE_URL_WEB` / `_ANDROID` (the `10.0.2.2` emulator case)
stay as they are.

Two consequential non-code changes:

1. **`AURIX_LOGIN_REDIRECT_URI` must remain `aurix://login-callback`** and must
   stay listed in the server's `OAUTH_APP_REDIRECTS` — that allow-list is what
   stops the API posting a one-time credential to an arbitrary URL.
2. **`PUBLIC_API_URL` becomes the Vercel origin**, which changes all four OAuth
   callback URLs. They must be re-registered in the Google, Apple, Facebook and
   GitHub consoles; Apple additionally requires domain verification. **This
   cannot be automated and is the longest-lead item in the whole migration.**

---

## 9. Verification plan

A migrated route is "done" only when its contract test passes.

| Stage | Check |
|---|---|
| Per-route | Contract test: same status, same body keys, same error `code` as `server/`. Fixtures captured from the Express app before it is retired. |
| Auth | All 6 doors → identical session payload; refresh rotation; revoke-all on password change; enumeration resistance on `login` + `password/forgot` (**including timing**). |
| Ownership | Every per-user route with another account's token → 403/empty. `GET /profile/:uid` with a foreign uid → 403. |
| Admin | Non-admin token on every `A` route → `admin_only`. Last-admin demotion → 400. |
| Uploads | PNG/JPEG/GIF/WebP accepted; **SVG rejected**; renamed `.png` script rejected; oversize → `payload_too_large`. |
| Serverless | Cold start (no boot phase); concurrent invocations do not open extra pools; rate limits hold across instances. |
| Flutter | Full Dart suite (48 files) + manual: sign-in ×6, playlist CRUD, reorder incl. rebalance, like/unlike, import, theme, avatar. |
| E2E | Flutter → Vercel → Next.js → Atlas, on device, against production. |

---

## 10. Open questions

| # | Question | Default if unanswered |
|---|---|---|
| O1 | `web/` vs another name for the Next.js app | D1 — Flutter → `mobile/` |
| O2 | Response envelope | D2 — preserve verbatim |
| O3 | `/api/v1` vs `/api` | D3 — keep `/api/v1` |
| O4 | Rate-limit store: Mongo or Upstash Redis | D4 — Mongo |
| O5 | Albums/artists/genres: omit, or design as new features | D5 — omit |
| O6 | Do you have the four OAuth provider consoles to hand? Apple domain verification gates Phase 12. | Assumed yes; flagged as longest-lead |

---

*Phase 2 complete. No source file has been modified.*
