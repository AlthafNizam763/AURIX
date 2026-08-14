# AURIX

> Your sound. Your universe.

A premium **black-and-white** music app for Android and iOS, built in Flutter on
**Firebase**. Your account, playlists, liked songs and listening history are
yours — stored against a Firebase account, synced to every device you sign in
on, and readable offline.

> ### ⚠️ This README predates the Firebase refactor
>
> Most of what follows still describes AURIX as a Spotify client, which it no
> longer is. The current architecture is documented in
> **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**, with setup in
> **[.env.example](.env.example)** and the test plan in
> **[docs/TESTING.md](docs/TESTING.md)**. Read those first; treat the sections
> below as accurate only where they describe the design system, the icon set
> and the background-playback plumbing.
>
> **In short:** sign-in is email and password through Firebase
> Authentication. Spotify is optional — one screen under Settings → Import
> music that copies playlists into your own library, plus the provider that
> currently plays full tracks. A build with no Spotify credentials at all is a
> complete, working AURIX.

The interface is strictly monochrome — one nine-step greyscale ramp, white as the
only accent, and every gradient derived from a cover converted to greyscale. The
artwork keeps its colour; nothing else has any. See
[Design system](#design-system) for why that constraint drives almost every
decision in the UI layer.

AURIX is an independent client. It is **not affiliated with, endorsed by, or
connected to Spotify AB**. No Spotify logo, icon, artwork or other protected
asset is reproduced anywhere in the app; the name, mark and interface are
original.

---

## Table of contents

- [What it does](#what-it-does)
- [How playback works — read this first](#how-playback-works--read-this-first)
- [Requirements](#requirements)
- [Setup](#setup)
  - [1. Create a Spotify application](#1-create-a-spotify-application)
  - [2. Configure the app](#2-configure-the-app)
  - [3. Run it](#3-run-it)
- [Architecture](#architecture)
- [Project structure](#project-structure)
- [Design system](#design-system)
- [Authentication](#authentication)
  - [Local backend](#local-backend)
- [Testing](#testing)
- [Building for release](#building-for-release)
- [Platform configuration reference](#platform-configuration-reference)
- [API limitations](#api-limitations)
- [Troubleshooting](#troubleshooting)
- [Licence and terms](#licence-and-terms)

---

## What it does

**Home** — nine shelves built from live Spotify data, all of it the signed-in
user's own: recently played, your playlists, trending (your top tracks),
recommendations, top artists, liked songs, saved albums, artists you follow,
and genre/mood tiles. Every shelf loads independently, and a shelf with no data
is hidden rather than shown empty — so a brand-new account sees fewer sections,
never broken ones.

Nothing on Home depends on `/browse/*`; those endpoints are closed to
Development Mode apps and were removed rather than retried. See
[`docs/API_LIMITATIONS.md`](docs/API_LIMITATIONS.md).

**Search** — debounced full-catalogue search across songs, artists, albums and
playlists, with a "Top result" card, per-type tabs with infinite scroll, locally
stored recent searches, and genre browsing.

**Artist** — immersive blurred header, follow/unfollow, popular tracks,
albums, singles & EPs, appears-on, and related artists.

**Album** — large artwork, gradient derived from the cover, full track list
with disc grouping, save, share, play and shuffle.

**Playlist** — artwork, description, owner, followers, full track list, save,
share, and track removal for playlists you can edit.

**Player** — full-screen with artwork-derived gradient and blurred backdrop,
scrubber, shuffle, repeat, queue and device selection. Dedicated landscape
layout.

**Dynamic Island** — an optional floating music pill at the top of the app.
Collapsed it shows the cover, the title, a live equaliser and play/pause;
tapped, it expands into artist line, progress and full transport, then folds
itself away after four idle seconds. Swipe up on it to open the player.

**It is off until you turn it on**, in **Settings → Appearance → Dynamic
Island**. A fresh install starts with it off, and so does a reinstall — AURIX's
preferences are excluded from Android's cloud backup precisely so that an
opt-in feature cannot arrive already switched on (see
`android/app/src/main/res/xml/`; the trade-off is that every preference resets
on reinstall, because backup rules cannot exclude a single key). Nothing but
the switch in Settings ever writes it: not first launch, not an update, and
there is no prompt asking you to enable it.

While it is off it costs nothing — no timer, no ticker, no listener, and no
playback processing of its own. `DynamicIslandLayer` reads the one boolean and
hands the app straight back. Switch it off mid-song and the pill goes at once;
playback, the mini player and the lock-screen controls are untouched, because
the island only ever reads the playback state that `PlayerController` already
owns. It runs no engine of its own and issues no Spotify request of its own.

It is drawn by AURIX and owes nothing to the hardware. Nothing detects a
device model or measures a cutout — the pill hangs below whatever the platform
reserves at the top, so a notch, a punch-hole, an iPhone's own Dynamic Island
and a flat-topped screen all get the same control in the same place relative to
their own hardware.

**Leaving the app.** The pill is a Flutter widget, and a Flutter widget stops
being drawn the moment Android moves AURIX off screen. What continues is the
media notification and the lock-screen controls, which are always on and do not
depend on this switch. On Android you can additionally let the island itself
follow you out — **Settings → Appearance → Dynamic Island → Keep it visible
outside AURIX** — which needs Android's "Display over other apps" permission,
is explained before it is requested, and is never asked for by anything else.
On iOS that would be a Live Activity, which needs a widget extension this build
does not ship; Settings says so rather than offering a switch that does
nothing. The whole design is written up in
[docs/BACKGROUND_PLAYBACK.md](docs/BACKGROUND_PLAYBACK.md).

**Queue** — now playing plus reorderable, swipe-to-remove "Next up".

**Library** — liked songs, playlists, albums, followed artists and recently
played, with filter chips, sort, and instant local search.

**Profile & Settings** — account, playback preference, audio, notifications,
appearance, privacy, storage and about.

Everything works offline in read-only form: metadata you have viewed is cached
and served with a clear "showing saved details" state.

---

## How playback works — read this first

**A third-party app cannot decode Spotify's audio.** There is no API that
returns a playable stream for a catalogue track, and building one would require
circumventing DRM. AURIX does not do that.

It uses the two mechanisms Spotify authorises, and picks between them per
track:

### Spotify Connect — full tracks

AURIX sends transport commands to a Spotify client the user already has
running (desktop app, phone, web player, speaker). That client plays the track.

- Requires **Spotify Premium**
- Requires an **active Spotify device**
- AURIX never receives the audio

### Preview clips — 30 seconds

Spotify publishes a 30-second MP3 for many tracks (`preview_url`). AURIX
streams it with `just_audio` and `audio_service`, with background playback and
lock-screen controls.

- Streamed, never downloaded or stored
- **Null for most apps registered on or after 27 November 2024**

### When neither is available

The app says so. It shows the reason and the remedy — "Open Spotify on a
device", "Premium is required" — and the progress bar does not move. There is
deliberately no code path that reports a track as playing without a real audio
source behind it. This is enforced by `PlaybackResolver` and covered by
[`test/unit/playback_resolver_test.dart`](test/unit/playback_resolver_test.dart).

The scrubber also never lies about length: while a preview is playing it shows
0:30 and labels itself, not the track's real duration.

---

## Requirements

| | |
|---|---|
| **Flutter** | 3.41.0 or newer (developed against 3.41.7) |
| **Dart** | 3.11.0 or newer |
| **Android** | minSdk 23 (Android 6.0), targetSdk per Flutter default |
| **iOS** | 13.0 or newer |
| **Spotify** | A free Spotify Developer account. **Premium is required for full playback** — see above. |

No code generation step. There is no `build_runner`, no `.g.dart` files and
nothing to regenerate — `flutter pub get` and run.

---

## Setup

### 1. Create a Spotify application

1. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
   and sign in.
2. **Create app**. Any name and description will do.
3. Under **Redirect URIs**, add one entry per platform you intend to build for.
   Each must match character for character — a mismatch is the single most
   common setup failure.

   | Platform | Redirect URI |
   | --- | --- |
   | Android / iOS | `aurix://auth-callback` |
   | Flutter Web (local) | `http://127.0.0.1:8080/auth.html` |
   | Flutter Web (deployed) | `https://your-domain/auth.html` |

   Two rules Spotify enforces on the web entry, both since the November 2025
   OAuth migration:

   * **`localhost` is rejected.** Use the loopback literal `127.0.0.1` (or
     `[::1]`). AURIX rewrites `localhost` → `127.0.0.1` when it derives the URI
     itself, but a value you register or set by hand is used verbatim.
   * **Anything that is not a loopback address must be `https`.**

   Custom schemes such as `aurix://` remain supported for mobile — they were
   not part of that migration.

4. Under **Which API/SDKs are you planning to use?**, tick **Web API**.
   AURIX uses no other Spotify SDK.
5. Under **User Management**, add every Spotify account that will sign in —
   including your own. A Development Mode app admits **up to five** accounts,
   and everyone else gets `403` on every request. Enter each account's full
   name and the email address it is registered with.
6. Save, then copy the **Client ID**.

> **There is no client secret to copy.** AURIX uses the Authorization Code
> flow with PKCE, which is what Spotify documents for public clients. No secret
> is needed, and none is ever compiled into the binary.

> **The dashboard account must have Spotify Premium.** Since February 2026 a
> Development Mode app only functions while the account that *owns* it holds an
> active Premium subscription — separate from whichever account signs in. If it
> lapses the app returns `403` for everything until that account resubscribes.
> See [`docs/SPOTIFY_DASHBOARD.md`](docs/SPOTIFY_DASHBOARD.md) for the full
> current rule set and what it costs this app.

### 2. Configure the app

```bash
cp .env.example .env        # macOS / Linux
Copy-Item .env.example .env # Windows PowerShell
```

Then fill in your Client ID:

```ini
SPOTIFY_CLIENT_ID=your_client_id_here
SPOTIFY_REDIRECT_URI=aurix://auth-callback
SPOTIFY_CALLBACK_SCHEME=aurix
SPOTIFY_REDIRECT_URI_WEB=
AUTH_PROXY_BASE_URL=
```

`.env` is git-ignored. `.env.example` is committed as the template.

`SPOTIFY_REDIRECT_URI_WEB` is only read on Flutter Web. **Keep it pinned.**
Leaving it blank means "derive `<origin>/auth.html` from wherever the app is
being served", and `flutter run -d chrome` takes a random OS port unless
`--web-port` says otherwise — producing a different `redirect_uri` on every
launch (`http://127.0.0.1:51066/auth.html`, then `:52310`, …). None of them can
be registered, and Spotify answers **"redirect_uri: Not matching
configuration"**. Run web with a port that matches the pinned value.

For a deployed build, point it at the real origin instead:

```ini
SPOTIFY_REDIRECT_URI_WEB=https://aurix.example.com/auth.html
```

The optional auth proxy has a key per platform, because a local backend does
not have one address — see [Local backend](#local-backend). All blank by
default, which is correct: PKCE needs no backend.

**Alternative — `--dart-define`** (preferred for CI and release builds):

```bash
flutter run \
  --dart-define=SPOTIFY_CLIENT_ID=your_client_id_here \
  --dart-define=SPOTIFY_REDIRECT_URI=aurix://auth-callback
```

`--dart-define` takes priority over `.env`. If neither is present the app opens
a setup screen explaining exactly what is missing rather than failing later.

### 3. Run it

```bash
flutter pub get
flutter run
```

On **Flutter Web**, pin the port so it matches `SPOTIFY_REDIRECT_URI_WEB`:

```bash
flutter run -d chrome --web-port 8080
```

Adding `--web-hostname 127.0.0.1` is optional but tidier:

```bash
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 8080
```

Without it Flutter serves on `localhost`, while Spotify requires the redirect
URI to use the literal `127.0.0.1`. Those are the same machine but *different
browser origins*, so the callback page cannot talk back to the tab that opened
it by default. AURIX bridges the gap — `web/auth.html` posts to both loopback
spellings, and the auth call declares which origin to expect — so plain
`--web-port 8080` works. Pinning the hostname simply removes the hop.

Either way the boot log tells you exactly what was sent:

```
[aurix.boot] config[.env] platform=web client_id=… redirect=http://127.0.0.1:8080/auth.html …
```

If the port does not match the pinned URI, the boot log says so before Spotify
ever sees the request.

> `.env` is bundled as an asset, so a change to it needs a **full restart**, not
> a hot reload.

#### Changing the URL scheme

If you use something other than `aurix://`, change it in **four** places or
the OAuth redirect will not come back:

1. `.env` → `SPOTIFY_REDIRECT_URI` and `SPOTIFY_CALLBACK_SCHEME`
2. `android/app/src/main/AndroidManifest.xml` → the `<data android:scheme="…">`
   entries in **both** intent filters: the deep-link one on `MainActivity`
   (which lists the content hosts) and the OAuth one on `CallbackActivity`
   (host `auth-callback`)
3. `ios/Runner/Info.plist` → `CFBundleURLSchemes`
4. `web/auth.html` — no change needed, but the **path** must keep matching
   `Env.webCallbackPath` if you rename the file

…and register the new URI in the Spotify dashboard.

> The two Android intent filters must not overlap. `MainActivity` enumerates
> its deep-link hosts (`track`, `album`, `artist`, `playlist`) precisely so it
> cannot also match `aurix://auth-callback`; a bare `<data android:scheme=
> "aurix"/>` there would put it in competition with `CallbackActivity` for the
> OAuth redirect, and Android would resolve the tie with a chooser dialog or an
> arbitrary pick. Sign-in then hangs until it times out.

---

## Architecture

Strict unidirectional dependencies. A widget never touches Dio, and the network
layer never knows about routes.

```
     Widget (ConsumerWidget)
          │  watch / read
          ▼
     Riverpod provider
          │
          ▼
     Repository            ← caching, fallbacks, composition, offline
          │
          ▼
     Spotify service       ← one class per API area, thin
          │
          ▼
     Dio + interceptors    ← auth, retry, error mapping
          │
          ▼
     Spotify Web API
```

**Key decisions and why:**

| Decision | Reason |
|---|---|
| Hand-written models, no `freezed`/`json_serializable` | Zero codegen step: clone and run. Spotify's responses need defensive parsing anyway (see `Json` in `data/models/json_utils.dart`) — a null `track` inside a playlist is real, and generated parsers throw on it. |
| One `ApiException` type | Nothing above the network layer sees a `DioException`, and no raw exception text can reach a user. `ErrorMapper` is the only place that reads Dio errors. |
| `QueuedInterceptor` for auth refresh | The home screen fires eight parallel requests. An expired token means eight simultaneous 401s; without single-flight coordination that is eight refresh calls racing, seven of which invalidate the token the eighth just stored. |
| Shelves fetched concurrently and independently | Endpoint availability varies by app, account and scope. A sequential build would be as slow as the sum of its parts and as fragile as its weakest endpoint. |
| Immutable `PlaybackQueue` with a separate order permutation | Toggling shuffle off restores the true album order instead of leaving a scrambled list. Removing a track rewrites the permutation so later tracks do not shift. |
| Palette extraction cached in a bounded LRU | Quantising a bitmap per scroll frame is not viable; results are memoised and in-flight requests shared. |
| `bootstrap()` returns provider overrides | Async setup (preferences, connectivity, audio service) completes before the first frame, and tests can skip it entirely. |

---

## Project structure

```
lib/
├── core/
│   ├── config/          Env — .env + --dart-define resolution
│   ├── constants/       endpoints, scopes, app constants
│   ├── network/         Dio client, auth + retry interceptors, error mapping
│   ├── providers/       the dependency graph
│   ├── router/          GoRouter, routes, transitions
│   ├── storage/         secure store (tokens), preferences, metadata cache
│   ├── theme/           AppColors, AppTypography, AppTheme, dimensions
│   └── utils/           formatters, debouncer, palette, responsive, share
│
├── data/
│   ├── models/          Track, Album, Artist, Playlist, Paging, …
│   ├── services/        SpotifyAuthService + 7 domain services + PKCE
│   └── repositories/    auth, home, catalogue, search, library
│
├── playback/            PlaybackQueue, PlaybackResolver, PlayerController,
│                        PreviewAudioHandler (audio_service)
│
├── features/
│   ├── splash/  onboarding/  auth/  shell/  home/  search/
│   ├── album/   artist/  playlist/ (detail + the Playlists page)
│   ├── player/  library/  profile/  settings/
│   ├── dynamic_island/  the floating pill — mounted above the Navigator
│   └── …each with screen + widgets/ + providers/
│
├── shared/widgets/
│   ├── brand/           AurixLogo (drawn in Dart, no raster assets)
│   ├── controls/        PlayButton, TransportButton, MusicProgressBar, …
│   ├── effects/         film grain, SoftReveal, glass panels, hairlines
│   ├── icons/           AurixIcon + 65 drawn glyphs (no Material icons)
│   ├── feedback/        skeletons, ErrorView, EmptyView, snackbars
│   ├── layout/          ImmersiveHeader, SectionHeader, DetailActionBar
│   ├── media/           AppArtwork, cards, SongTile
│   ├── search/          search bar, filter chips
│   └── sheets/          BottomSheetMenu, ConfirmDialog
│
├── app.dart             MaterialApp.router
└── main.dart            bootstrap() + runApp
```

---

## Design system

Strict monochrome, dark-first. No colour, size or text style is inlined in a
widget.

The palette is split in two. `AppColors` holds the **ramp and the dark-theme
constants** — the values `const` widget trees and `CustomPainter` defaults fall
back to. `AurixPalette` holds the **brightness-aware tokens** and travels on
`ThemeData` as an extension, read through `context.palette`.

A widget that reads `AppColors.textPrimary` directly is hard-coded to dark mode.
Reading `context.palette.textPrimary` is what makes it work in both.

### The ramp — `AppColors`

Nine steps, and their *spacing* is the whole design. With no hue, luminance is
the only axis left, so every separation the UI needs has to be bought with it.

| Token | Value | Use |
|---|---|---|
| `black` | `#000000` | the page |
| `blackDeep` | `#050505` | recessed wells |
| `surfaceDark` | `#0D0D0D` | cards, sheets |
| `surfaceElevatedTone` | `#151515` | inputs, mini player |
| `graphite` | `#222222` | pressed states, tooltips |
| `gray` | `#666666` | disabled, footnotes |
| `grayLight` | `#A0A0A0` | metadata |
| `whiteSoft` | `#F5F5F5` | the pressed accent |
| `white` | `#FFFFFF` | titles, and the accent |

The four darkest steps sit within 13% luminance of each other. That tight
cluster is what lets a card sit on a surface on a background and still read as
three layers — depth in AURIX comes from stacking these, never from a border.
Then there is a deliberate void between `graphite` and `gray`: nothing lives
between `#222222` and `#666666`, and that gap is what makes text pop off a card
instead of fading into it.

**The accent is white.** With no hue to spend, the primary action colour is pure
white on black — 21:1 against its label, the highest contrast sRGB allows. This
is why the play button is a white disc with a black glyph: not a stylistic
choice, but the only way to make one element outrank everything else when
everything else is grey. Its scarcity is the mechanism, which is why
`ColorScheme.secondary` and `tertiary` are routed to *surfaces* rather than to
the accent — pointing them at white would make every chip shout as loudly as the
play button.

**Status has no alarm hue.** `error`, `warning`, `success` and `info` are all
neutrals, separated by luminance and always paired with a glyph and a sentence.
`AurixPalette.attention` is the brightness-aware version. If a destructive action
ever needs a true red, that is the one value to change.

### Light mode — designed, not inverted

Swapping black for white produces a theme that looks like a bug. Two departures:

- **Elevation reverses direction.** In dark, a surface gets lighter as it rises.
  In light, the page rests at `#F2F2F2` so a card can rise *to* white — so in
  both themes "raised" means "closer to the light", and neither has a card that
  looks like a hole.
- **Light ink is `#0A0A0A`, not black.** Pure black on white haloes at body
  size. Near-black still clears AAA.

`test/unit/theme_contrast_test.dart` enforces the WCAG floors for **both**
themes, and asserts the monochrome invariant directly: every ramp step, every
status colour and every token in both palettes has `r == g == b`. That test is
the identity expressed as code — AURIX can survive a spacing regression, but not
a hue appearing in the ramp.

### Artwork, in greyscale

Covers keep their colour — they are content. Everything *derived* from them is
converted to greyscale, because a derived wash is UI, and UI carries no hue here.
Left in colour, a magenta sleeve turns the whole player magenta and the identity
is gone for as long as that track plays.

`AlbumPalette` samples a cover and keeps the one property that survives the
conversion — how bright it is — so a washed-out ambient cover still gets a
lighter header than a black metal sleeve. It converts via **Rec. 709 relative
luminance, not HSL desaturation**: HSL lightness is not perceptual, so a
saturated yellow and a saturated blue at the same nominal lightness desaturate to
the *same grey*, and two covers that look nothing alike would produce identical
headers. The player's full-bleed backdrop uses the matching `ColorFilter.matrix`.

The result is the effect the whole design is built around: one saturated object,
sharp, on a monochrome field derived from itself.

### Texture and depth

Three painters in `shared/widgets/effects/`, all deliberately low-alpha — they
should register as structure, not decoration.

| Widget | What it draws |
|---|---|
| `GrainPainter` | film grain — a jittered-grid scatter with a fade direction |
| `SoftReveal` | the settle: 8px rise, 1.5% scale, late fade, on content *replacement* |
| `GlassPanel` / `HairlineFrame` / `SoftLift` | frosted panels, hairline borders, soft lifts |

**Grain is load-bearing, not decorative.** AURIX puts large flat near-black
fields behind almost everything, and an 8-bit gradient across that much black
*bands* into visible steps — worse on OLED, which renders the darkest steps
perfectly. The scatter dithers it. It is a **jittered grid** (one grain placed
randomly inside each cell), because a regular grid reads as a mesh and uniform
random placement clumps into what looks like dirt on the lens. Stratified
sampling has neither failure, and is also what film grain physically is.

Glassmorphism is confined to the four surfaces that earn it: the mini player,
the bottom navigation, floating controls and player overlays. `BackdropFilter`
forces a saveLayer and reads back the framebuffer, so one or two per screen is
fine and one per list row is not — which is why the card and tile widgets do not
use it.

There is no bloom anywhere. A white glow on a near-black field is the single
fastest way to make a monochrome interface look cheap, and it would outrank the
play button. Depth is a black shadow plus a surface step.

**Testing note:** `pumpAndSettle` never returns on a tree containing a playing
`PlayButton` — it animates continuously by design. Those tests pump fixed
durations instead.

### Icons

**The app ships no Material icons.** All 65 glyphs are drawn in Dart, for the
same reasons the logo is: they stay crisp at every density, add nothing to the
bundle, and follow the active theme's ink between light and dark.

Mixing a themed interface with stock glyphs is the fastest way to make a
custom design look unfinished, so the set covers everything on screen —
navigation, transport, library, account, status, browse-category tiles and the
appearance picker. `grep -r 'Icons\.' lib` returns nothing but a model field
that happens to be called `icons`.

| File | Holds |
|---|---|
| `icons/aurix_icon_geometry.dart` | the 24×24 grid, stroke constants and shape primitives |
| `icons/aurix_glyphs.dart` | `AurixGlyph` — every glyph, built from those primitives |
| `icons/aurix_icon.dart` | `AurixIcon` widget + painter, and the emphasis treatment |

`AurixIcon` is a drop-in for `Icon`: it resolves size and colour from the
ambient `IconTheme`, so `IconButton`, `ListTile` and `AppBar` style it without
any call site changing.

Two rules give the set one voice, and both live in the *painter* rather than in
each drawing — which is what stops sixty-five separately-drawn shapes from each
interpreting the brand slightly differently:

1. **One geometry.** Every glyph is authored on a 24×24 grid with a 2.0 stroke
   and round terminals, then scaled at paint time.
2. **Emphasis is a field, not a colour.** A selected tab or an engaged shuffle
   gains a soft filled disc behind the glyph, in the accent at low alpha.

Rule 2 used to be a chromatic fringe — two offset copies in the accent and the
cold accent. That is impossible here, and instructively so: an RGB split needs
two *hues* to separate. Drawn in a palette where both are white it stops being a
fringe and becomes a blurry glyph. A backing disc distinguishes the state by
**area** instead, which survives being drawn in the same white as everything
around it.

The same trap caught the transport controls: shuffle and repeat used to say
"engaged" by turning the accent colour, which silently stopped working the moment
the accent became white — the resting glyph was already white. They now use the
brighter of two greys plus the emphasis disc.

Emphasis is dropped automatically below 20px and whenever `IconTheme.opacity` is
under 1 — a disc behind an 18px glyph swallows it, and lighting a dimmed icon
would undo the disabled signal.

Because the glyphs are painted rather than font-mapped, `find.byIcon` does not
work on them. Tests use `findGlyph(AurixGlyph.x)` from the harness instead.

`test/widget/aurix_icon_test.dart` rasterises **every** glyph and asserts it
puts ink on the canvas, stays inside its box, and renders at every size the app
uses (11–64px). It runs over the whole enum rather than a hand-listed sample,
so a glyph added later cannot skip the checks — and it has already caught two
real bugs: a `skipPrevious` whose bar overlapped its own triangle, and glyphs
that silently painted nothing.

### Typography

Set in **Manrope**, bundled as a single 165KB variable file.

AURIX has no colour to carry its identity, so the typeface does work a logo and
an accent hue would normally share. Manrope is geometric with near-circular
bowls, and it holds its shape at the wide tracking the wordmark needs — which is
exactly where a default UI face falls apart. One file covers the 200–800 weight
range, renders identically on every platform, and never touches the network.

Weights come from `fontVariations` on the `wght` axis, not from `fontWeight`
alone: registering the same file once per weight would load the same 165KB under
seven names. Every style sets both, so `TextStyle.lerp`, `apply()` and the
accessibility bold-text setting keep behaving sensibly. The scale stays `const`
so roughly two dozen call sites can say `const Text(..., style: …)`.

**The wordmark** is `A U R I X` — rendered with proportional tracking rather than
literal spaces. Spaces are a fixed width from the font and would not scale; more
importantly, a screen reader announces `"A U R I X"` as five separate letters and
text search stops matching the word. `AurixWordmark` keeps the accessible name
"AURIX" while the rendering stays spaced.

**The mark** is the letter A, cut: two legs meeting at a rounded apex, and a
crossbar that does not touch them. That gap is the whole mark — the eye closes an
A from far less, and the floating bar reads simultaneously as a level meter,
which is the only nod to audio the identity makes. It replaced a swept ring
wrapping a play triangle: a pictogram of playback says "media player" and has to
compete with every other rounded glyph on a home screen, where a letterform says
*brand*.

`tool/generate_launcher_icons.dart` rasterises the same geometry for the launcher
icons, so the app icon and the in-app mark cannot drift.

**Animations** honour both the OS "reduce motion" setting and the in-app
toggle, checked through a single `MediaQuery.disableAnimations` in `app.dart`.
Widgets that own an `AnimationController` build it in `initState`
unconditionally — a lazy `late final` is never touched when animations are off,
which made `dispose()` the first access and threw
`Looking up a deactivated widget's ancestor is unsafe`. Pinned by
`test/widget/reduced_motion_disposal_test.dart`.

---

## Authentication

**Authorization Code + PKCE** (RFC 7636), the flow Spotify documents for public
clients.

```
App                          System browser              Spotify
 │ generate verifier + S256 challenge
 │──── open /authorize?code_challenge=… ──────────────────▶│
 │                                          user signs in  │
 │◀──── aurix://auth-callback?code=…&state=… ────────────│
 │ verify state
 │──── POST /api/token  (code + verifier, no secret) ──────▶│
 │◀──── access_token + refresh_token ──────────────────────│
 │ store in Keystore / Keychain
```

The same flow runs on Flutter Web, with one substitution: a browser cannot
follow a custom scheme, so the redirect goes to `<origin>/auth.html` instead.
That page posts the callback URL back to the app and closes itself — the
authorization code never leaves the origin, and the verifier never leaves the
Flutter app.

```
Flutter Web ──▶ Spotify login ──▶ /auth.html ──postMessage──▶ Flutter Web
```

- **No client secret** anywhere in the app, on any platform. PKCE proves
  possession of a per-request secret that never leaves the device.
- **State parameter** verified on the callback; a mismatch aborts before the
  code is exchanged.
- **Ephemeral browser session** (`preferEphemeral: true`) so account switching
  works and nothing is left in the system browser. Native platforms only; on
  web the popup carries the browser's own session.
- **Platform-correct redirect URI**, resolved at runtime: the custom scheme on
  Android/iOS, `<origin>/auth.html` on web. Register both in the dashboard.
- **Tokens** in the Android Keystore / iOS Keychain via
  `flutter_secure_storage`, with `first_unlock_this_device` so they never reach
  an iCloud backup. Never in SharedPreferences, never in a log line.
- **Automatic refresh** 60 seconds before expiry, single-flight so parallel
  requests share one refresh.
- **Rotation-safe**: a refresh response that omits `refresh_token` means "keep
  the one you have" — dropping it would log the user out an hour later.
- **Logout** destroys local credentials. Spotify has no revocation endpoint for
  PKCE clients; the ephemeral session means nothing is left behind either.

`AUTH_PROXY_BASE_URL` is optional and off by default, for deployments that
prefer token exchange server-side. It is not required — PKCE needs no backend.

### Local backend

There is **no backend in this repository** and none is needed: AURIX exchanges
tokens directly with `accounts.spotify.com`. This section applies only if you
add the optional proxy yourself.

A local backend cannot be reached at one address from every platform, because
`localhost` means a different machine on each:

| Running on | `AUTH_PROXY_BASE_URL_*` to use |
| --- | --- |
| Browser on the dev PC | `AUTH_PROXY_BASE_URL_WEB=http://127.0.0.1:<port>` |
| Physical phone, same Wi-Fi | `AUTH_PROXY_BASE_URL_MOBILE=http://<PC-LAN-IP>:<port>` |
| Android emulator | `AUTH_PROXY_BASE_URL_MOBILE=http://10.0.2.2:<port>` |
| iOS simulator | `AUTH_PROXY_BASE_URL_MOBILE=http://127.0.0.1:<port>` |

The platform-specific key wins when set; `AUTH_PROXY_BASE_URL` is the shared
fallback. AURIX warns at boot if a native build is pointed at loopback, because
on a physical phone that resolves to the phone, not to your PC — the request
never leaves the device and fails as "connection refused".

For a phone to reach a backend on your PC, three things must all be true:

1. **The backend binds to `0.0.0.0`, not `127.0.0.1`.** A server bound to
   loopback accepts nothing from the network, whatever the firewall says.
2. **The port is allowed through the Windows firewall.** In an elevated
   PowerShell, substituting your port:

   ```powershell
   New-NetFirewallRule -DisplayName "AURIX dev backend" -Direction Inbound `
     -Protocol TCP -LocalPort <port> -Action Allow -Profile Private
   ```

   Keep it to `-Profile Private`; opening a dev port on a public network
   profile exposes it to every machine on, say, a café Wi-Fi.
3. **Android permits cleartext to that host.** Android 9+ blocks plain HTTP by
   default. Debug builds allow it for the development machine only, via
   [`android/app/src/debug/res/xml/network_security_config.xml`](android/app/src/debug/res/xml/network_security_config.xml)
   — edit the LAN address there if you work on a different machine. Release
   builds are untouched and still require HTTPS.

   On iOS, App Transport Security blocks it too. Nothing is declared in
   `Info.plist` because nothing currently needs it; a local http backend would
   require an `NSAllowsLocalNetworking` exception, and adding one to a shipping
   build is a decision worth making deliberately.

`adb reverse tcp:<port> tcp:<port>` avoids all three: it forwards the device's
own loopback to the host over USB, so `http://127.0.0.1:<port>` works on the
phone with no LAN address, no firewall rule, and no cleartext exception beyond
the loopback entry already present.

---

## Testing

```bash
flutter test                                  # 188 unit + widget tests
flutter test test/unit                        # unit only
flutter test --coverage                       # with coverage
flutter test integration_test/app_flow_test.dart -d <device>   # needs a device
```

**Unit** — PKCE correctness (S256 digest, unpadded base64url, entropy), model
parsing including the awkward real-world shapes, queue mechanics
(shuffle/repeat/reorder/remove), playback-mode resolution, error mapping
including every 403 reason, and each Spotify service against a recording HTTP
adapter that asserts what was actually requested.

**Widget** — song rows, error/empty/offline states, play button, scrubber
(including that a drag reports exactly one seek), mini player across preview
and Connect modes, bottom navigation, and the home screen through
loading → data → empty → error.

The Dynamic Island tests mount it where it really lives — above the
`Navigator`, inside `MaterialApp`'s builder — rather than in a `Scaffold`,
because most of its failure modes are consequences of that position and
disappear under a friendlier wrapper. They pin the collapse/expand morph
(including that reversing it part-way through does not snap), the idle
fold-away and its reset, that the pill takes only its own taps and lets the
rest of the screen through, and that it hangs below the safe area across five
fabricated top insets from a flat-topped screen to a hardware cutout.

**Integration** — cold start routing, tab switching, library filtering, and the
mini player staying absent until something genuinely plays.

Things that need a real account and a second device are listed as a manual
checklist in [`docs/API_LIMITATIONS.md`](docs/API_LIMITATIONS.md#manual-verification-checklist).
A test that pretended to cover them would be worse than none.

---

## Building for release

### Android

```bash
flutter build apk --release \
  --dart-define=SPOTIFY_CLIENT_ID=… \
  --dart-define=SPOTIFY_REDIRECT_URI=aurix://auth-callback

flutter build appbundle --release --dart-define=…
```

Before publishing, replace the debug signing config in
`android/app/build.gradle.kts` with your own keystore. `key.properties` and
`*.jks` are already git-ignored.

R8 is enabled with rules in `android/app/proguard-rules.pro` covering
`audio_service`, ExoPlayer, `flutter_web_auth_2` and `flutter_secure_storage` —
all of which are instantiated reflectively or from the manifest and would
otherwise be stripped.

### iOS

```bash
flutter build ipa --release --dart-define=…
```

Set your team and bundle identifier in Xcode. Background audio is already
declared in `Info.plist`.

### Launcher icons

The in-app logo is drawn procedurally, but the launcher icons are still
Flutter's defaults. Replace them before shipping — e.g. with
[`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons).

---

## Platform configuration reference

### Android — `AndroidManifest.xml`

| Entry | Why |
|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | API calls; offline detection |
| `WAKE_LOCK` | preview playback with the screen off |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | background audio (the subtype is required from Android 14) |
| `POST_NOTIFICATIONS` | media notification on Android 13+ |
| `AudioService` + `MediaButtonReceiver` | `audio_service` background playback and hardware media keys |
| `CallbackActivity` (`aurix://auth-callback`, `taskAffinity=""`) | captures the OAuth redirect. The empty task affinity is required by `flutter_web_auth_2` — without it the callback can reorder `MainActivity` and drop the pending auth session |
| `<data android:scheme="aurix" android:host="…">` on MainActivity, one per content host | deep links. Hosts are enumerated (`track`, `album`, `artist`, `playlist`) so this filter cannot also match `aurix://auth-callback` and compete with `CallbackActivity` for the OAuth redirect |
| `<queries>` for `https` and Custom Tabs | required from Android 11 for `url_launcher` and the auth browser |

`MainActivity` extends **`AudioServiceActivity`**, not `FlutterActivity` — with
the default base class, playback stops the moment the app is backgrounded.

### iOS — `Info.plist`

| Entry | Why |
|---|---|
| `UIBackgroundModes: audio` | background preview playback, lock-screen controls |
| `CFBundleURLTypes` → `aurix` | OAuth redirect and deep links |
| `LSApplicationQueriesSchemes` | `url_launcher` capability checks |

No App Transport Security exception is declared or needed — everything is
HTTPS.

`ASWebAuthenticationSession` delivers the OAuth callback directly to the
in-flight session, so no `openURL` handling is needed in `AppDelegate` or
`SceneDelegate` for sign-in — registering the scheme is sufficient.

### Web — `web/auth.html`

| Entry | Why |
|---|---|
| `web/auth.html` | the page Spotify redirects to. Posts `{'flutter-web-auth-2': location.href}` to `window.opener`, falling back to `window.parent` (iframe) and then `localStorage` (popup blocked) |
| `SPOTIFY_REDIRECT_URI_WEB` | overrides the derived `<origin>/auth.html`; leave blank for local development |

The message key and shape are dictated by `flutter_web_auth_2` — do not rename
them. `postMessage` uses an explicit same-origin target, never `"*"`.

---

## API limitations

Spotify restricted a group of endpoints on 27 November 2024, and preview URLs
are no longer populated for new apps. AURIX works around each of these with a
fallback that returns **real** Spotify data, never fabricated content.

**[Read `docs/API_LIMITATIONS.md`](docs/API_LIMITATIONS.md)** for the full list,
what each fallback does, and why.

---

## Troubleshooting

**"redirect_uri: Not matching configuration" (web)**
Almost always a random dev-server port. `flutter run -d chrome` — and the
VS Code / Android Studio run buttons, which pass no port at all — take an
OS-assigned port, so the derived redirect URI is different on every launch and
no dashboard entry can match it. The boot log now says so outright:

```
[aurix.boot] The dev server is on a random port (51066), so this build sends
             redirect_uri=http://127.0.0.1:51066/auth.html — a value that
             changes every launch and cannot be registered.
```

Fix it by pinning the port, then registering the pinned URI:

```bash
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 8080
# then register http://127.0.0.1:8080/auth.html in the dashboard
```

From an IDE, use the **"AURIX (web · 127.0.0.1:8080)"** configuration in
[`.vscode/launch.json`](.vscode/launch.json) rather than the bare run button —
that is what passes the flags.

**"INVALID_CLIENT: Invalid redirect URI"**
The URI in the dashboard does not match the one this build sent, exactly. Check
for a trailing slash, and remember it is case-sensitive. The boot log prints
the value actually used:

```
[aurix.boot] config[.env] platform=web client_id=… redirect=… token_endpoint=…
```

**"redirect_uri: Not matching configuration" on web**
The dev server took a random port, so the redirect URI was something like
`http://127.0.0.1:51066/auth.html` — different on every launch and impossible
to register. Two things must agree:

1. `SPOTIFY_REDIRECT_URI_WEB` in `.env` is pinned to
   `http://127.0.0.1:8080/auth.html` (it is, by default).
2. The app is served on that same port: `flutter run -d chrome --web-port 8080`.

If they disagree, the boot log says so explicitly rather than letting Spotify
reject it. Also check the dashboard has the URI character for character —
`localhost` is rejected outright, and a trailing slash counts as different.

**Login opens the browser, then nothing happens**
On **Android/iOS**: the custom scheme is not registered. Check the
`CallbackActivity` intent-filter in `AndroidManifest.xml` and
`CFBundleURLSchemes` in `Info.plist`. Both must be `aurix` (or your scheme),
and both need a full rebuild — not a hot restart.

If Android shows a *"Open with…"* chooser at the moment Spotify redirects, two
intent filters are both claiming `aurix://auth-callback`. `MainActivity`'s
deep-link filter must enumerate its content hosts rather than matching the bare
scheme — see "Changing the URL scheme".

On **web**: check that `web/auth.html` is being served (open
`<origin>/auth.html` directly — it should say "Authentication complete"), and
that the popup was not blocked. A blocked popup still completes via
`localStorage`, but only if the page was reached at all.

**Setup screen appears even though `.env` is filled in**
`.env` is an asset. Stop the app and run again; hot reload will not pick it up.

**"Spotify is blocking this account" (the access-denied screen)**
Sign-in worked, but `GET /me` came back `403`. That is Spotify refusing the
*application* on behalf of *this account* — nothing in AURIX can grant it. The
screen prints what Spotify actually said, plus the Client ID the build is
running as; the same line is in the console:

```
[aurix.auth] Spotify refused GET /me for this account — 403 on /me — …
```

* `User not registered in the Developer Dashboard` — the app is in Development
  Mode. Dashboard → your app → Settings → **User Management** → add the full
  name and email of the Spotify account you signed in with. That is not
  necessarily the account that owns the dashboard app. Since February 2026 the
  cap is **five** accounts, not 25.
* No message at all — either the app has not declared the Web API (Dashboard →
  Settings → Edit → tick **Web API** → Save), or the account that *owns* the
  dashboard app no longer has Spotify Premium. Since February 2026 a
  Development Mode app stops working entirely when the owner's subscription
  lapses, and resumes when they resubscribe. See
  [`docs/SPOTIFY_DASHBOARD.md`](docs/SPOTIFY_DASHBOARD.md).
* `Insufficient client scope` — sign out and back in so the consent screen
  runs again.

Check the Client ID on screen against the dashboard first. Editing the settings
of a *different* app than the one `.env` points at is the most common wasted
hour here.

**Sign-in fails with "We couldn't find that on Spotify"**
`AUTH_PROXY_BASE_URL` is set to a host that does not implement `/token` and
`/refresh`, so the token exchange 404s. Unless you are deliberately running the
optional proxy, leave it **blank** — PKCE needs no backend. A value that is not
an absolute `http(s)` URL is ignored, and the boot log says so.

**"No Spotify device available"**
Working as intended — open Spotify anywhere and play something for a second, so
the device registers, then refresh the picker.

**Everything loads but nothing plays**
Check the account tier on the Profile screen. Free accounts cannot use Spotify
Connect, and most new developer apps get no preview URLs. The device picker
explains which of the two applies.

**Shelves are missing from Home**
Expected on a new app or a new account. Each shelf needs a different endpoint
and some need listening history; unavailable ones are dropped rather than shown
as errors. See `docs/API_LIMITATIONS.md`.

**Build warns "flutter_secure_storage requires Android SDK version 37 or higher"**
Expected, and the build still succeeds. Every module is pinned to
`compileSdk 36` in `android/build.gradle.kts` because AGP 8.11 cannot resolve
the SDK's new minor-versioned `android-37.0` platform and fails with
*"Failed to find target with hash string 'android-37'"*. `compileSdk` only
affects what the code is compiled against — `minSdk` and `targetSdk` are
untouched, so runtime behaviour is unchanged. Remove the pin once AGP is new
enough to understand minor SDK versions.

**Build fails on `Failed to find target with hash string 'android-37'`**
The pin above is missing or was removed. Restore the `subprojects` block in
`android/build.gradle.kts`, or install the exact SDK platform AGP is asking for.

**Build fails on `minSdkVersion`**
`flutter_secure_storage` needs API 24 for AES-GCM in the Android Keystore.
Flutter's default already satisfies this; if you have lowered `minSdk`, raise
it back or login will fail on the first token write.

---

## Licence and terms

AURIX is a sample application. Using it means agreeing to the
[Spotify Developer Terms of Service](https://developer.spotify.com/terms) and
the [Design Guidelines](https://developer.spotify.com/documentation/design).

Notably: you may not download or store Spotify audio, circumvent DRM, or use
Spotify content to train machine-learning models. This project does none of
those things, and the architecture is deliberately shaped so it could not do
them accidentally.

Album art, artist images and metadata are loaded from Spotify's CDN at runtime
and belong to their respective owners. Nothing is redistributed with this
repository.
