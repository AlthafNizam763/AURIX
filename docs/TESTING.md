# Testing AURIX

## Automated

```
flutter test          # 750 tests, all passing
flutter analyze       # clean
```

### What the suite covers

| Suite | What it holds |
|---|---|
| `test/unit/track_key_test.dart` | Deterministic document ids — idempotent likes, de-duplicating re-import |
| `test/unit/firestore_models_test.dart` | Document round-trips; `Json.timestamp` against all four shapes |
| `test/unit/playlist_position_test.dart` | Fractional ordering, including gap collapse after ~50 subdivisions |
| `test/unit/import_service_test.dart` | Import mapping, re-import, rename propagation, partial failure |
| `test/unit/search_service_test.dart` | Merge order, de-duplication, one-provider-down |
| `test/unit/env_redirect_test.dart` | Firebase config gating; redirect URI derivation |
| `test/widget/login_screen_test.dart` | Sign-in/registration form, validation, layout at five viewports |
| `test/widget/home_screen_test.dart` | Shelf assembly from live Firestore streams |
| `test/widget/avatar_picker_test.dart` | The bundled-avatar rule, asserted on the widget tree |
| `integration_test/app_flow_test.dart` | Router, shell, tabs, and that Spotify is reachable only via Settings |

### What it deliberately does not cover

Firebase is stubbed in every test. The real `AuthController` subscribes to
`authStateChanges` and the real library providers open Firestore listeners —
neither of which a test process should be initialising. What is verified is the
app's own wiring: routers, redirects, providers, screens.

**A passing `flutter test` is not evidence that the security rules are
correct.** Rules run on Google's servers. See the emulator section below.

---

## Against the Firebase emulator

The honest test of the rules and of the real write paths.

```bash
firebase emulators:start --only auth,firestore
```

Then point a debug build at the emulator and work through the checklist below.

### Rules — the checks that matter

| Check | Expected |
|---|---|
| Read `/users/{someone-else}` while signed in | **Denied** |
| Read `/users/{someone-else}/playlists` | **Denied** |
| Write to `/users/{own-uid}/playlists/{id}` | Allowed |
| Write any path while signed out | **Denied** |
| Write a 2 MB string as a playlist name | **Denied** (bounded) |
| Change `createdAt` on your own user document | **Denied** |
| Delete `/users/{own-uid}` | **Denied** |
| Write to a top-level collection, e.g. `/playlists/x` | **Denied** |

---

## Manual checklist

Everything here needs a real device or a configured Firebase project.

### Authentication
- [ ] Register a new account — a `/users/{uid}` document appears with the name,
      email and `avatar_01`
- [ ] Sign out, sign back in — library intact
- [ ] Wrong password → "That email and password do not match an AURIX account"
- [ ] Register with an address already in use → offered sign-in instead
- [ ] Forgot password → mail arrives; the app says the same thing whether or not
      the address is registered
- [ ] Change password from Edit Profile; the old one stops working
- [ ] Kill and relaunch the app — still signed in, no login flash
- [ ] Sign in on a second device — same library

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
- [ ] Aeroplane mode → Home, Library, Liked Songs and playlists all still render
- [ ] Create a playlist and like a song offline
- [ ] Restore the network → both appear on the second device
- [ ] The offline banner shows and clears

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
