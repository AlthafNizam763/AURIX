# Theming

How AURIX's appearance is configured, where each value lives, and what an
administrator can and cannot change.

---

## The idea

Every colour, the type scale and the player layouts used to be compile-time
constants. Changing any of them meant editing Dart and shipping a build.

They are now one document in MongoDB, fetched on launch and applied to the whole
widget tree through `ThemeData`. The constants did not go away — they are
`ThemeConfig.fallback`, and they are what renders when there is no server, no
network and no cache.

```json
{
  "version": 7,
  "fontFamily": "Poppins",
  "primaryColor": "#FFFFFF",
  "secondaryColor": "#222222",
  "accentColor": "#E50914",
  "backgroundColor": "#000000",
  "surfaceColor": "#0D0D0D",
  "textColor": "#FFFFFF",
  "playerColor": "#151515",
  "buttonColor": "#FFFFFF",
  "appLogo": "/api/v1/assets/6710f2…",
  "musicPlayer": {
    "mini": "theme1",
    "large": "theme2",
    "outside": "theme1",
    "dynamic": "theme4"
  }
}
```

The flat colour keys above are the documented format and describe the **dark**
colourway. The document also carries the canonical nested form —
`colors.dark` and `colors.light` — which is what the app actually applies,
because AURIX follows the device's light/dark setting and a configuration with
only one colourway would leave the other unstyled.

`PUT /api/v1/theme` accepts either spelling.

---

## Where to change it

Two surfaces, same API, same document.

**In the app** — Settings → Appearance, visible only to administrators. Colours,
type, logo, and the player-theme grid. Every control previews live: the screen
you are looking at *is* the preview, and nothing is written until you press
Save.

**On the web** — `http://<your-api>/admin/`, served by the API itself. Everything
the in-app screen does, plus font-file upload and asset management. Sign in with
an administrator account.

Font *files* are web-only. Choosing a family is in both; supplying a TTF for one
is a once-a-deployment task that is better done by dropping a file on a desktop
than by digging through a phone's storage, and doing it in-app would mean adding
a heavyweight file-picker plugin for it.

---

## The launch sequence

```
  Application start
        ↓
  Cached configuration         ← rendered on the FIRST frame, no await
        ↓
  Fetch from the API (MongoDB) ← behind the splash screen
        ↓
  Register the font            ← the previous face keeps rendering
        ↓
  Rebuild with the new palette, logo and player themes
```

The order is the design:

- **Cache first** is what makes the first frame carry the operator's branding
  rather than the shipped default. The *raw response* is cached rather than the
  parsed object, because asset paths are resolved against the API base URL at
  parse time and caching the resolved form would bake yesterday's base URL into
  today's logo.
- **Fetch behind the splash** keeps a slow network off the launch path. A theme
  that cannot be loaded leaves the app rendering its previous appearance — the
  user asked for their music, not for a theme.
- **Register the font last** stops a font download from reflowing every screen
  twice. `ThemeState.fontFamily` is the family that is *actually registered
  right now*, which is not always the configured one, and the app rebuilds once
  when the real one becomes available.

And when a setting changes:

```
  Admin changes a setting
        ↓
  Save to MongoDB          (ApiThemeService)
        ↓
  Cache the new document   (preferences, same call)
        ↓
  Register the font if it changed
        ↓
  Emit new state → MaterialApp rebuilds → every screen repaints
```

`version` is bumped by the server on every write and is the cache key. Comparing
two integers is how the client decides whether to rebuild; deep-comparing two
config objects would be the alternative.

---

## The eight roles, and the twenty-six tokens

An administrator sets eight colours. The palette a widget reads has
twenty-six. The rest are derived by `AurixPalette.fromConfig`.

| Role | What it paints |
|---|---|
| `primary` | Headings, active tabs, the brand mark |
| `secondary` | Chips, dividers, the top surface layer |
| `accent` | Play button, focus rings — the one thing to press |
| `background` | The page itself |
| `surface` | Cards, sheets, list rows |
| `text` | Body and title text |
| `player` | Mini player and full player background |
| `button` | Filled-button fill |

Exposing all twenty-six would be a form nobody can fill in correctly, and it
would let an operator produce combinations that are not merely ugly but
unreadable. Two derivation rules are worth knowing:

- **Text steps are blends toward the background, not opacities.** A secondary
  label at 60% alpha over artwork picks up the artwork; the same colour blended
  against the background stays a flat tone.
- **Ink on a filled surface is computed, never configured.** An operator who
  sets a yellow accent and expects a white glyph has made the play button
  invisible. The ink is chosen by luminance against a threshold of **0.179** —
  not 0.5, which is the intuitive answer and is wrong by a factor of two in the
  worst case. `theme_config_test.dart` sweeps the sRGB cube to confirm the
  resulting guarantee of ≥4.5:1.

Nothing tries to *correct* a bad palette. A background and a text colour that
are both mid-grey will produce low-contrast text; that is the operator's
decision, and the Appearance screen warns before it ships rather than silently
overriding it.

---

## Presets

Eight roles across two colourways is sixteen decisions, which is the right
amount of power for a deployment with a brand book and far too much for the
commoner case of "make it darker". `ThemePresets` (`lib/core/theme/
theme_presets.dart`) collapses those sixteen into one tap.

| Preset | What it is |
|---|---|
| `Default` | The shipped AURIX identity — monochrome, no hue anywhere |
| `Spider-Verse` | Halftone magenta and cyan on ink |
| `Midnight` | Cool navy, desaturated |
| `AMOLED` | `#000000` background — unlit pixels on an OLED panel |
| `Custom` | Not a choice; what the colours are called when they match no preset |

Three properties are worth stating because each one is a decision that could
reasonably have gone the other way.

**A preset writes both colourways, always.** AURIX follows the device's
light/dark setting unless the user overrides it, so writing only the one being
edited would apply the preset to roughly half the users. The Appearance
screen's brightness toggle chooses what you are *previewing*, not what a preset
writes.

**A preset is a colourway and nothing else.** Font, type scale, player designs
and uploaded logos are left alone. Someone who chose Poppins and then tried
Midnight has not asked to lose Poppins.

**Which preset is selected is derived, never stored.** There is no preset id on
the wire. `ThemePresets.matching` compares the config's colours against each
preset and returns `custom` when none matches. A stored id would be a second
source of truth about the colours, and the two drift the first time anything
writes colours without going through the picker — a server-side edit, a
restored backup, an older client. The result would be a screen that says
"Midnight" while showing something else, which is worse than saying nothing.
Deriving it costs one comparison of eight values and meant the wire format did
not have to change to gain the feature.

Every preset is asserted against WCAG AA in `test/unit/theme_presets_test.dart`
— body text on background, on surface and on the player, for both colourways.
A preset is the one path where the operator does not see the individual colours
before applying them, so shipping one that fails contrast would hand someone an
unreadable app in a single tap.

---

## Typography

Configurable: the family, one **scale multiplier**, one **tracking delta**, and
four weight steps (body, title, heading, display).

Not configurable: the relative sizes. The ratios between display, headline,
title and body are the hierarchy, and an operator handed fifteen independent
point sizes will eventually flatten them into a wall. A multiplier cannot.

Tracking is a *delta* for the same reason: the display styles are set at −1.8
and the overline at +1.8, and one absolute value would destroy both registers.

Every style sets both `fontWeight` and `fontVariations`. The `wght` axis is what
renders on a variable font like Manrope; `fontWeight` is what a non-variable
uploaded font honours, and what `TextStyle.lerp` and the accessibility
bold-text setting use.

### Fonts

Six families ship in the app and always work, offline and on the first frame:
**Manrope** (the brand face and the guaranteed fallback), **Poppins**,
**Inter**, **Roboto**, **Montserrat** and **Oswald**. Selecting any of them in
the Appearance screen applies immediately, on desktop and mobile alike, with no
upload and no network.

They are bundled rather than fetched, and the reason is a failure that was easy
to miss: the picker listed all six while only Manrope had a file behind it, so
choosing "Poppins" left `FontRegistry` with nothing to register, degraded to
the fallback exactly as designed — and looked indistinguishable from a bug.

Two lists have to agree for a bundled family to work: `fonts:` in
`pubspec.yaml`, which decides what the engine can resolve, and
`FontRegistry.bundled`, which decides what the app believes it can resolve
without downloading. Neither checks the other, and a disagreement is silent in
both directions, so `test/unit/bundled_fonts_test.dart` asserts it.

Any *other* family is uploaded through the web panel, stored in GridFS,
downloaded once by the client, registered with `FontLoader`, and cached in the
application-support directory so it survives being offline. An uploaded font
overrides a bundled one of the same name, so this list is a floor and not a
ceiling.

A family selected with no font file behind it is **not an error**: an
administrator can pick one before uploading it. The app logs it and keeps
rendering the previous face, and the picker shows the family as needing an
upload rather than hiding it.

Poppins publishes no variable file, so its four weights are registered
individually and selected by `fontWeight`; the other five are single variable
files selected along the `wght` axis. Every style sets both, which is what
makes the two cases interchangeable — see the note above.

---

## Player themes

Four surfaces, four designs each (`theme1`–`theme4`), chosen independently.

| Surface | What it is |
|---|---|
| Mini | The bar above the tabs while something is playing |
| Large | The full-screen player |
| Outside | The OS notification and lock screen |
| Dynamic | The floating Dynamic Island pill |

They are independent because they are genuinely different components rather than
one component at four sizes — a single "player theme" setting would have to mean
four different things at once.

### How they are implemented, and why not the obvious way

The obvious way to ship four mini-player themes is four copies of the mini
player. It is also the way that guarantees they drift: a fix to the buffering
state, or the Connect-device row, or the semantics label lands in one copy and
not the other three. The full player is worse — it is seven hundred lines.

So the logic stays where it is, and a variant supplies a small value object
describing the chrome: shape, fill treatment, artwork size, control
arrangement. See `lib/core/theme/player_themes.dart`. Every variant inherits
every bug fix, and adding a fifth is a constant rather than a file — one on
each of the four style classes, a case in each `of()`, and an entry in the
server's `PLAYER_VARIANTS`. The exhaustive switches make the compiler list the
places, which is why they are not defaulted.

**No field in those descriptors is a `Color`.** Every variant paints from the
configured palette, so changing the player colour is visible in all four and a
variant cannot smuggle in a colour the theme did not authorise. What varies is
form.

### The outside player is the honest exception

That surface is drawn by Android and iOS, not by AURIX. The system decides the
typeface, the colours and the layout; an app controls which transport actions
exist, which are promoted into the collapsed view, and whether artwork is
attached. Its four variants are real but modest, and an operator expecting the
notification to follow their palette should be told it will not.

---

## Uploads

Logos, icons and font files go to GridFS in the same database, served back
through `GET /api/v1/assets/:id`.

Every upload is identified by its **magic bytes**. A `Content-Type` header and a
`.png` extension are both supplied by the caller, and an admin panel is exactly
the surface where "upload an image" turns into "serve arbitrary content from our
origin". The stored content type is the one the server decided, and it is served
with `X-Content-Type-Options: nosniff`.

SVG is deliberately refused for logos. An SVG is a document that can carry
script, and serving one from the API origin is a stored-XSS vector against the
admin panel that a raster format does not have. The cost is uploading a PNG or
WebP instead, which is what the app renders anyway.

Caps: 2 MB for an image, 4 MB for a font, both enforced before the bytes are
read.

---

## Fallbacks

A missing value is filled in three times over, and the redundancy is the point:

1. **The server** normalises on write *and* on read, so the stored document is
   always complete.
2. **`ThemeConfig.fromJson`** defaults every field again, so a response from an
   older API — or a cache written by an older build — cannot produce a null.
3. **`ThemeConfig.fallback`** is what is used when there is no configuration at
   all.

Any one failing leaves the other two, and the failure mode of the whole chain is
"the app looks like it shipped", not "the app is black on black".

`theme_config_test.dart` asserts that a default configuration reproduces the
shipped palette exactly for every role that is a direct assignment — which is
what makes the theme system invisible to a deployment that never opens the admin
panel.
