# Testing AURIX

## Automated

```bash
flutter test          # 929 tests, all passing
flutter analyze       # clean

cd server && npm test # 71 tests, all passing
```

### What the Flutter suite covers

| Suite | What it holds |
|---|---|
| `test/unit/track_key_test.dart` | Deterministic document ids — idempotent likes, de-duplicating re-import |
| `test/unit/document_models_test.dart` | Document round-trips; `Json.timestamp` against all four shapes |
| `test/unit/playlist_position_test.dart` | Fractional ordering, including gap collapse after ~24 subdivisions |
| `test/unit/live_query_test.dart` | Invalidation, prefix matching, coalescing, failure handling — what replaced snapshot listeners |
| `test/unit/theme_config_test.dart` | Theme parsing, defaulting, palette derivation, the sRGB contrast sweep |
| `test/unit/import_service_test.dart` | Import mapping, re-import, rename propagation, partial failure |
| `test/unit/search_service_test.dart` | Merge order, de-duplication, one-provider-down |
| `test/unit/env_redirect_test.dart` | API config gating; that no MongoDB URI can reach the client; redirect URI derivation |
| `test/widget/login_screen_test.dart` | Sign-in/registration form, validation, layout at five viewports |
| `test/unit/auth_methods_test.dart` | The wire contract for sign-in methods: provider ids, an unknown provider being dropped rather than crashing, the cached account round-trip, the link challenge |
| `test/widget/sign_in_methods_test.dart` | That the login screen offers exactly what the server reports and nothing more; that the layout survives five more buttons; the phone and account-link sheets; that every brand mark paints |
| `test/widget/appearance_test.dart` | A configured theme reaching `ThemeData`, and the admin controls including the preset picker |
| `test/unit/theme_presets_test.dart` | The named colourways: that each is detected after being applied, that one edited colour makes the selection Custom, that a preset touches nothing but colour, and WCAG AA for all four in both colourways |
| `test/widget/home_screen_test.dart` | Shelf assembly from the library streams |
| `test/widget/avatar_picker_test.dart` | The bundled-avatar rule, asserted on the widget tree |
| `integration_test/app_flow_test.dart` | Router, shell, tabs, and that Spotify is reachable only via Settings |

### What the server suite covers

| Suite | What it holds |
|---|---|
| `server/test/search.test.js` | The tokeniser, asserted against the Dart original it was ported from |
| `server/test/theme.test.js` | Theme normalisation, colour parsing, fractional positions |
| `server/test/sample-data.test.js` | The demo catalogue: unique ids, resolvable playlist references, genre and album coverage, that every recording carries a public-domain or Creative Commons licence, and that every song is findable through the real query path |
| `server/test/auth.test.js` | Phone canonicalisation (every spelling of one number to one string), which provider addresses may be matched on, that no user view can serialise a password hash, that a one-time code reaches no log line, that phone is advertised only when it can be delivered, the redirect allow-list, dead-end page escaping |

`server/test/search.test.js` earns its place: the two halves of search now run on
different sides of the network — the client writes the token arrays, the server
queries them — so a drift between the two implementations does not look like a
crash, it looks like an empty catalogue.

### What it deliberately does not cover

The API is stubbed in every widget test, by pointing a real `AurixApiClient` at
an empty base URL. Every call then fails with `not_configured` *before* touching
the network, and every service above it already handles that — theme fetches
return null, catalogue searches return empty — because those are the same paths
that run on a device with no connection. That exercises the real error handling
rather than replacing it with a mock.

**Nothing here has been run against a live MongoDB.** `npm test` covers the pure
logic; every route, index and aggregation is unexercised against a real server.
See the verification section of `docs/MONGODB_MIGRATION.md` for the full list of
what was and was not run.

---

## Demo data

An empty database cannot be tested: every screen degrades to its empty state,
search returns nothing, and the four player surfaces have nothing to draw — so
"does the mini player theme apply?" is not a question anyone can answer.

```bash
cd server
npm run seed:samples              # verify every URL, then write
npm run seed:samples -- --check   # verify only; touch nothing
npm run seed:samples -- --clear   # remove exactly what the seed wrote
npm run seed:samples -- --force   # write anyway (offline)
```

Twenty songs across five genres and six albums, six shared playlists, and the
playlist-song ordering. The manifest is
`server/scripts/sample-data/catalogue.js`.

**Every recording is public domain, CC0, or Creative Commons Attribution, and
every one is hosted by Wikimedia Commons.** That is the same rule the importers
obey, stated in data rather than in code. A demo catalogue full of chart pop
with `previewUrl` pointing at some scraped CDN would contradict every safeguard
in `AudioSourceResolver` and `SpotifyPlaylistFetcher`, and would be the single
most likely thing in the repository to end up in production by accident. The
`license` and `attribution` fields travel with each row, so the claim is
auditable from the database rather than asserted once in a comment.

These are the only rows AURIX may stream end to end — `source: 'aurix'`, no
provider id — which makes them the only way to exercise the resolver's
`licensedPreview` branch with a *full* track rather than a thirty-second clip.

Two details that are easy to get wrong and are handled:

- **Ogg would work on Android and fail on iOS.** Commons publishes an MP3
  transcode of every audio file at a derived path, and that is what
  `previewUrl` points at. A test asserts every URL ends in `.mp3`.
- **A `429` is not a broken link.** Wikimedia refuses sustained ranged reads of
  transcoded audio, and an unthrottled first pass over these twenty-six URLs
  reported fourteen "broken" that all returned `206` a minute later. The
  verifier therefore has three outcomes, not two: a `4xx` or a wrong
  content-type is *broken* and stops the seed; a `429` or `5xx` is
  *unverified*, which warns but does not block. A seed that will not run
  because a CDN was busy is a worse failure than the one it exists to prevent.

Re-running is safe. Every id is a fixed slug and every write is an upsert keyed
on it, so a second run refreshes the same twenty songs rather than creating
twenty more.

---

## Against a real API

The honest test of the write paths. Point a local MongoDB or an Atlas cluster at
the server and work through the checklist below.

```bash
cd server
cp .env.example .env      # fill in MONGODB_URI and the JWT secrets
npm install && npm start
```

Watch the boot log: it names the database it connected to and the indexes it
created. Then point a debug build at it with `AURIX_API_BASE_URL`.

### Authorisation — the checks that matter

`firestore.rules` is gone; the equivalent is that the client cannot phrase a
query about another account. These are the checks that confirm it.

| Check | Expected |
|---|---|
| `GET /api/v1/profile/{someone-else}` with a valid token | **403** |
| Any `/api/v1/*` call with no `Authorization` header | **401** (except `/theme` and `/assets/*`, which are public by design) |
| Any call with an expired token | **401 `token_expired`**, then a silent refresh and replay |
| `PUT /api/v1/theme` as a non-admin | **403 `admin_only`** |
| `DELETE /api/v1/shared-playlists/{id}` as a non-importer | **403** |
| A playlist name of 2 MB | **400 `bad_request`** (bounded) |
| A track body with an extra field | Accepted, field **stripped** rather than stored |
| 25 failed logins from one IP inside 15 minutes | **429 `rate_limited`** |
| `POST /auth/password/forgot` for an address that does not exist | **200**, same body as for one that does |
| Uploading a `.png` that is actually a script | **415 `unsupported_media_type`** |

### Appearance

| Check | Expected |
|---|---|
| Change a colour in Settings → Appearance | The app repaints under your finger, before saving |
| Leave without saving | Prompted; discarding restores the server's version |
| Save, then relaunch | The new palette is on the **first frame**, from cache |
| Save, then relaunch with the API stopped | Still the new palette — the cache is authoritative offline |
| Upload a logo | Replaces the drawn mark everywhere, including the splash screen |
| Reset the logo | Returns to the drawn mark; no broken image at any point |
| Pick a font with no file uploaded | The app keeps its current face and logs why |
| Change the mini player theme | The bar changes shape without interrupting playback |
| Change the mini player theme only | The large, outside and dynamic players are untouched |
| Tap a preset — Spider-Verse, Midnight, AMOLED | The whole app repaints, and the eight pickers below now show that preset's colours |
| Tap a preset, then flip Dark/Light | Both colourways changed — a preset writes both |
| Tap a preset, then move one colour picker | The selection above becomes **Custom** |
| Tap a preset after choosing a font | The font is unchanged; a preset is colour only |
| Save a preset, then relaunch | The preset is still shown as selected, not as Custom |
| Open Appearance on a fresh install | **Default** is selected, not Custom |

---

## Manual checklist

Everything here needs a real device and a running API.

### Authentication
- [ ] Register a new account — a row appears in the `users` collection with the
      name, email and `avatar_01`, and a bcrypt hash rather than a password
- [ ] Sign out, sign back in — library intact
- [ ] Wrong password → "That email and password do not match an AURIX account"
- [ ] Register with an address already in use → offered sign-in instead
- [ ] Forgot password → mail arrives; the app says the same thing whether or not
      the address is registered
- [ ] Change password from Edit Profile; the old one stops working
- [ ] Kill and relaunch the app — still signed in, no login flash (the tokens
      come out of the platform keystore during `bootstrap()`)
- [ ] Leave the app open past the access token's 30 minutes, then act — the
      request refreshes silently and succeeds, with no visible interruption
- [ ] Change your password on device A — device B is signed out at its next
      refresh, and A is not
- [ ] Sign in on a second device — same library

### The other ways in

Needs real provider credentials in `server/.env` and, for the phone flow, an SMS
provider — none of this is exercised by `npm test`, and the provider modules are
written from documentation rather than from a run.

- [ ] `GET /api/v1/auth/methods` lists exactly the providers configured; the
      login screen draws a button for each and none for the rest
- [ ] Remove a provider's credentials, restart — its button disappears rather
      than failing when tapped
- [ ] **The code is nowhere but the handset.** Run `POST /auth/phone/start` and
      read the raw response — it carries `ok`, a message, a masked number and
      two durations, and no code. Then check the server's stdout, and the app's
      `flutter logs`, for the six digits that arrived by SMS. Finding them
      anywhere is the failure this whole path is built to prevent.
- [ ] With Twilio unconfigured: `GET /auth/methods` omits `phone`, the login
      screen shows no Phone button, and calling `/auth/phone/start` directly
      returns 503 `otp_unavailable` — with no row added to `otpCodes`
- [ ] Phone: code arrives, signs in, and creates a `users` row with a `phone`
      and **no `email` field at all** (not an empty string — check with
      `db.users.find({ email: { $exists: false } })`, which is what the sparse
      index depends on)
- [ ] Phone: a second phone-only account registers successfully — this is the
      case a non-sparse email index silently refuses
- [ ] Phone: "OTP sent successfully" appears when the code goes out, and is
      replaced — not stacked — by the error when a wrong code is submitted
- [ ] Phone: wrong code five times burns it ("Invalid"), waiting past
      `OTP_TTL_MINUTES` reports expiry, asking for a new one inside 30 seconds
      is refused with the remaining seconds, and six requests in an hour are
      refused. Four distinct messages, four distinct states
- [ ] Phone: the Resend button is disabled with a live countdown, and becomes
      enabled exactly when the server would accept another request
- [ ] Point Twilio at a number it will refuse (an unverified one on a trial
      account): the request fails cleanly *and* the row is gone from
      `otpCodes`, so the next attempt is not blocked by a code nobody received
- [ ] Google, Apple, Facebook, GitHub: each signs in, and signing in twice lands
      on the *same* uid with one row in `identities`
- [ ] Apple: the display name is captured on the very first authorization and
      the account keeps it afterwards; a Hide-My-Email account stores the relay
      address with `emailIsPrivateRelay: true` and is not offered as a match
- [ ] GitHub with a private profile email: the address still arrives (from
      `/user/emails`) and is marked verified
- [ ] **The link challenge.** Register with a password at an address, sign out,
      then "Continue with Google" using the same address: the sheet appears
      rather than a second account. Confirm with the password → one uid, two
      rows in `identities`+`users.passwordHash`. Check the `users` count did not
      increase.
- [ ] Link challenge with a wrong password five times destroys the grant and
      sends you back to the provider
- [ ] "That is not my account" removes the row from `authGrants` immediately
- [ ] Settings → Sign-in methods: add Google to a password account, then sign
      out and use it — same library
- [ ] Settings → Sign-in methods: removing the only method is refused, with the
      control disabled and "Your only way in" shown
- [ ] An account with no password can still set one (Settings → Sign-in methods
      → Email → Add) and can still delete itself
- [ ] Try to link a Google account that is already on another AURIX account →
      "already linked to a different AURIX account", and neither account changes
- [ ] Tamper with the final redirect: call `POST /auth/oauth/google/start` with
      a `redirectUri` that is not in `OAUTH_APP_REDIRECTS` → refused before a
      browser opens
- [ ] Replay a callback URL a second time → the dead-end page, not a second
      grant
- [ ] Redeem an exchange code twice → the second call is refused

### Profile
- [ ] Rename yourself; the home header and settings row follow
- [ ] Pick an avatar; every avatar surface changes at once
- [ ] The avatar is the same on the second device
- [ ] There is no upload, camera or file-picker affordance anywhere

### Library
- [ ] Create, rename and delete a playlist
- [ ] Add a track from the player's ⋯ menu
- [ ] Add one track to several playlists at once
- [ ] Remove a track — the undo puts it back
- [ ] Reorder by dragging; the order survives a relaunch
- [ ] Like a song in the player — the heart fills in the playlist behind it,
      and the row appears in Liked Songs, with no refresh
- [ ] Unlike from Liked Songs — the row leaves immediately
- [ ] Play something — it appears at the top of Recently Played

### Offline

Read the offline section of `docs/ARCHITECTURE.md` first — this regressed in the
MongoDB migration and the checklist reflects what is actually true now, not what
Firestore used to give for free.

- [ ] Aeroplane mode → the app launches, **branded**, and stays signed in
- [ ] Screens already visited this session keep what they were showing
- [ ] A screen not yet loaded shows its error state, with a retry
- [ ] Liking a song fails and says so — it is **not** queued
- [ ] The offline banner shows and clears
- [ ] Restore the network → a retry succeeds; nothing was lost that was saved

### Import — the acceptance test for the whole refactor
- [ ] Settings → Import music lists Spotify, and YouTube Music as "coming soon"
      with a reason
- [ ] Connect to Spotify; playlists are listed with covers and counts
- [ ] Nothing is pre-selected
- [ ] Import three; the progress bar names the playlist and counts songs
- [ ] The summary names anything that failed, individually
- [ ] The imported playlists are in the library, editable, on the Imported shelf
- [ ] **Import the same playlists again — nothing duplicates**
- [ ] **Then: sign out of Spotify entirely / revoke AURIX at
      spotify.com/account/apps, and relaunch.** Home, Library, Liked Songs,
      Playlists and Profile must all work exactly as before. This is the
      headline claim of the refactor and the one worth checking properly.

### Playback (needs Spotify installed and authorised)
- [ ] Play an imported track — App Remote drives the Spotify app
- [ ] The mini player and full player track it
- [ ] Lock-screen and notification controls work
- [ ] Background playback survives leaving the app
- [ ] The Dynamic Island / floating surface behaves as before
- [ ] Skipping *inside Spotify* is reflected in AURIX within a second
- [ ] An AURIX-native track with no Spotify id reports that it cannot be played
      rather than advancing a progress bar over silence

### Navigation
- [ ] All three tabs, and back from every detail screen
- [ ] Back from Home closes the app; back from anywhere else goes to Home
- [ ] Deep link to a playlist that does not exist → "Playlist not found"
