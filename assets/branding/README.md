# Custom brand assets

Drop a file named **`logo.png`** in this folder and AURIX uses it instead of
the procedurally-drawn mark — on the splash screen, the login hero, the setup
and access-denied screens, and the About page.

No code change is needed. The app probes for the file once at startup and falls
back to the drawn mark if it is absent or unreadable.

```
assets/branding/app_icon_source.webp
```

`app_icon_source.png`, already in this folder, is **not** that file — it is the
generated launcher icon, and it includes the dark rounded-square background. Do
not point the override at it: the in-app logo is placed on surfaces that supply
their own backdrop, so you would get a tile inside a tile.

## Requirements

| | |
|---|---|
| **Format** | PNG with transparency (the app places it on dark surfaces) |
| **Shape** | Square — it is rendered inside a square box and will letterbox otherwise |
| **Size** | 512×512 or larger. It is downscaled per use; the largest placement is 116 px logical, so ~350 px covers a 3× screen |
| **Padding** | Bake in ~8% breathing room. The drawn mark reserves this, and a full-bleed replacement will look cramped next to it |

After adding or removing the file, **stop and re-run** the app. Assets are
bundled at build time, so a hot reload will not pick it up.

## Launcher icons

`logo.png` only changes the in-app logo. The Android and iOS launcher icons are
generated separately, straight from the mark's geometry:

```bash
dart run tool/generate_launcher_icons.dart
```

That writes every Android density, the full iOS set, and `app_icon_source.png`
in this folder. The geometry constants in that script are mirrored from
`_AurixMarkPainter` in `lib/shared/widgets/brand/aurix_logo.dart` — change one
and change the other, or the launcher icon and the in-app mark drift apart.

## What can go here

Artwork you own, commissioned, or hold a licence for.

Not third-party logos, brand marks, or characters — including recoloured or
edited versions of them. That specifically rules out anything containing
Spotify's mark, since AURIX authenticates against Spotify's API and their
Developer Terms prohibit using their branding in a way that implies
affiliation. Doing it anyway risks the app's API access being revoked and will
fail app store review.
