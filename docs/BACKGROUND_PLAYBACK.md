# Background playback and the persistent Dynamic Island

How AURIX keeps playing, keeps its controls on screen, and keeps everything
saying the same thing once the app is no longer the app you are looking at.

---

## The shape of it

```
Spotify app  ──App Remote──┐
Connect device ──Web API───┤
                           ▼
                   PlayerController          ← the single source of truth
                           │
        ┌──────────────────┼───────────────────────┐
        │                  │                       │
   Flutter UI      PreviewAudioHandler      DynamicIslandController
   mini player      (audio_service)                 │
   full player             │                        │
   in-app island     MediaSession            platform bridge
   (foreground)            │                        │
                    ┌──────┴──────┐          ┌──────┴───────┐
                    │             │          │              │
              lock screen   media notif   Android:       iOS:
                                          overlay      Live Activity
                                          window       (see ios/LiveActivity)
```

One arrow matters more than the rest: **everything downstream of
`PlayerController` reads, and nothing downstream plays.** There is one Spotify
App Remote binding, one media session, one queue and one timeline. The island —
in the app or outside it — is a view onto that state and a set of buttons that
post back into it.

### Files

| Concern | Where |
| --- | --- |
| Playback state, queue, transport, timeline | [`lib/playback/player_controller.dart`](../lib/playback/player_controller.dart) |
| MediaSession, lock screen, notification | [`lib/playback/preview_audio_handler.dart`](../lib/playback/preview_audio_handler.dart) |
| Spotify app control | [`lib/data/services/spotify_app_remote_service.dart`](../lib/data/services/spotify_app_remote_service.dart) |
| Is AURIX on screen | [`lib/core/providers/app_visibility.dart`](../lib/core/providers/app_visibility.dart) |
| Floating-surface bridge and capabilities | [`lib/playback/background_island_channel.dart`](../lib/playback/background_island_channel.dart) |
| Deciding when a floating surface appears | [`lib/features/dynamic_island/providers/dynamic_island_controller.dart`](../lib/features/dynamic_island/providers/dynamic_island_controller.dart) |
| The in-app pill | [`lib/features/dynamic_island/dynamic_island.dart`](../lib/features/dynamic_island/dynamic_island.dart) |
| Notification permission | [`lib/playback/media_permissions.dart`](../lib/playback/media_permissions.dart) |
| Android overlay window | [`android/.../island/DynamicIslandOverlay.kt`](../android/app/src/main/kotlin/com/aurix/app/island/DynamicIslandOverlay.kt) |
| iOS Live Activity | [`ios/LiveActivity/README.md`](../ios/LiveActivity/README.md) |

---

## Three surfaces, and which one you get

| | AURIX open | AURIX minimised | Screen locked |
| --- | --- | --- | --- |
| **Music** | plays | plays | plays |
| **Media notification** | posted | posted | — |
| **Lock-screen controls** | — | — | shown |
| **In-app island** (opt-in) | shown | not drawable | not drawable |
| **Floating island** (opt-in²) | hidden, the pill has it | Android only, with the grant | not drawable |

The two "not drawable" cells are the platform limitation this design is built
around, not an omission. A Flutter widget cannot outlive its own app being
backgrounded, and nothing can draw over the Android keyguard. Those cases are
covered by the media notification and the lock-screen session, which is what
Android provides for exactly this and what the requirements ask us to prefer.

### Why the floating island hides when AURIX is open

The in-app pill *is* the island while the app is on screen. Drawing the overlay
too would put the same control on screen twice, one of them over the other.
`DynamicIslandController._shouldFloat` is where that swap happens, and the
handover is driven by `appVisibilityProvider` so both halves agree on the
instant it occurs.

---

## What keeps the process alive

`audio_service`'s Android service, declared in the manifest with
`foregroundServiceType="mediaPlayback"`. It has two jobs:

1. it plays Spotify's 30-second preview clips itself, and
2. it hosts the **MediaSession** for playback happening elsewhere — the Spotify
   app over App Remote, or a Connect device.

The second is the one that matters here. The session and the service belong to
the process rather than to `MainActivity`, so Android destroying the activity on
the way to the home screen leaves both running — and with them the App Remote
binding, the `PlayerController`, and the overlay window, which is added with the
**application** context for the same reason.

`MainActivity` extends `AudioServiceActivity`, and AURIX's own two plugins are
registered against the **engine** rather than the activity, so the channels keep
answering after the activity is gone.

**No second service exists, and nothing runs on a schedule.** The service starts
when playback starts and stops when it ends.

### The service stays foreground across a pause

`androidStopForegroundOnPause: false`, and that one line is the difference
between a notification that survives being backgrounded and one that does not.

With the default (`true`, which is what AURIX shipped first), pausing calls
`stopForeground()` and the next resume has to call `startForegroundService()`
again. From Android 12 that call throws `ForegroundServiceStartNotAllowedException`
when the app is in the background — and AURIX is *always* in the background at
that moment, because the resume came from the lock screen or from a state push
after the user pressed play inside the Spotify app. The exception is swallowed by
the platform channel, so the only visible symptom is that the notification never
comes back, for the rest of the session.

Keeping the service foreground makes pause and resume pure state updates with no
service transition to lose. Two consequences worth stating:

- `androidNotificationOngoing` must be `false` — `audio_service` asserts it. No
  loss: an ongoing notification is one the user cannot swipe away, and AURIX is
  not the thing making the sound.
- A partial wake lock (CPU only; the screen is unaffected) is held while paused.
  It is released when the session ends — playback stopping, the App Remote
  binding going away, or the user dismissing the notification.

### Dismissing the notification pauses Spotify

`BaseAudioHandler.stop` stops the *local* player, and under App Remote there is
no local player. So a swipe used to remove AURIX's controls and leave the music
playing with nothing on screen able to stop it. `PreviewAudioHandler.stop`
forwards to `PlayerController._onSessionStopRequested` while
[`remoteControlMode`](../lib/playback/preview_audio_handler.dart) is set, which
pauses Spotify first and takes the session down after it. The queue survives, so
the mini player stays populated and paused.

### The small icon is a mark, not the launcher icon

Android renders a notification's small icon from its **alpha channel** only,
filling the stencil with the system tint. A launcher icon is a fully opaque
square, so `audio_service`'s default of `mipmap/ic_launcher` draws a solid white
block in the status bar. AURIX ships
[`drawable/ic_stat_aurix`](../android/app/src/main/res/drawable/ic_stat_aurix.xml)
— the AURIX "A" as white-on-transparent geometry — and points the config at it.

### Errors are visible

`AudioService.asyncError` is logged at `initAudioService`. Everything the
platform side rejects arrives on that stream and nowhere else: `audio_service`
routes publish failures there rather than throwing into the caller, which is
correct (a lock screen must not be able to crash a music app) and is also why a
broken media session is otherwise completely silent. If the notification is
missing, `adb logcat -s flutter | grep media_session` is the first place to look.

### Tapping the notification opens the player

`androidNotificationClickStartsActivity` gets AURIX as far as *open*; the route
the user lands on is Flutter's decision.
[`MediaNotificationTaps`](../lib/playback/media_notification_taps.dart) listens
on `AudioService.notificationClicked` and pushes the player screen. It is mounted
from `AurixApp` rather than from a screen, because the tap arrives when AURIX may
have no screen mounted at all. It navigates and nothing else — a tap is a request
to look at what is playing, and the transport buttons are two millimetres away
for anyone who meant to press one.

### The notification permission

From Android 13 `POST_NOTIFICATIONS` is a runtime grant, and without it the
media notification never appears — the shade stays empty even though the session
is alive. Nothing in the Flutter media stack asks for it, so
[`MediaPermissionsPlugin`](../android/app/src/main/kotlin/com/aurix/app/media/MediaPermissionsPlugin.kt)
does, **once, as the first track starts** — never at launch, where the dialog
would arrive with no context. A refusal costs AURIX its own notification and
costs playback nothing.

---

## The timeline

```
Spotify PlayerState ──► PlayerController._anchorPosition ──► position + positionUpdatedAt
                                     │
                ┌────────────────────┼────────────────────┐
                ▼                    ▼                    ▼
        Flutter scrubber      PlaybackState        island frame
        (interpolates)     (updateTime + speed)   (interpolates)
```

**Spotify is the source of truth, and only Spotify.** Every surface interpolates
between anchors for smooth motion, and none of them accumulates:

- the Flutter scrubber recomputes from `_positionAnchor + elapsed`;
- Android's notification advances its own bar from `updateTime` and `speed`;
- the overlay recomputes from `positionMs + elapsed` in
  `DynamicIslandOverlay.projectedPositionMs`;
- the Live Activity would use `ProgressView(timerInterval:)`, animated by iOS.

An accumulator silently loses whatever time it was not scheduled for. A
projection cannot, which is what makes a ten-minute doze window cost nothing.

Anchors are re-established from Spotify on every App Remote push, on a five-
second reconciliation, and on every seek. `positionUpdatedAt` moves only on a
*real* anchor — interpolated ticks leave it alone — which is what the island
controller subscribes to, so a floating surface is re-synced on truth and never
on a tick.

---

## What changes when you press Home

| | Foreground | Background |
| --- | --- | --- |
| Ticker interval | 500ms | 5s |
| Position interpolation in Dart | yes | **no** |
| App Remote reconciliation | every 5s | every 5s |
| Connect polling | every 4s | every 15s |
| Flutter rebuilds from the timeline | yes | none — nothing is drawn |
| Island frames published | none, the pill reads state directly | on change only |

Interpolation exists to move a scrubber, and a backgrounded app has no scrubber
— the notification and the overlay each run their own projection. So the fast
tick is retired on the way out and what remains is the reconciliation the fast
tick was carrying anyway: one App Remote read every five seconds, which is a
local IPC call and not a network request.

The retiming happens on the visibility edge, in `PlayerController._retimeTicker`,
rather than as an early return inside `_onTick` — a 500ms timer that returns
early ten times a second is still a 500ms timer waking the isolate.

**Nothing is created on the way out and nothing is disposed.** No second
`PlayerController`, no second Spotify connection, no extra listener, no second
poll. The island controller holds two subscriptions and no timer at all.

---

## Permissions

| Permission | When | Asked how |
| --- | --- | --- |
| `INTERNET`, `ACCESS_NETWORK_STATE`, `WAKE_LOCK` | always | manifest, no prompt |
| `FOREGROUND_SERVICE`, `..._MEDIA_PLAYBACK` | always | manifest, no prompt |
| `POST_NOTIFICATIONS` | first track plays | system dialog, once |
| `SYSTEM_ALERT_WINDOW` | **only** on an explicit tap in Settings | AURIX explains it, then opens the system screen |

The overlay grant is the one worth being careful about, and the route to it is
deliberately long: **Settings → Dynamic Island (off by default) → Keep it
visible outside AURIX → a dialog explaining what Android calls "Display over
other apps" → the system screen.** No playback path, no launch path and no
onboarding path reaches it. It is declared in the manifest because a special app
access cannot be requested otherwise; declaring it grants nothing.

Two separate preferences back this, both defaulting to off and both excluded
from Android's cloud backup so a reinstall cannot arrive with either already on:

- `aurix.settings.dynamic_island` — the feature.
- `aurix.settings.dynamic_island_overlay` — permission to leave the app.

Switching the feature off withdraws the second automatically. Neither switch
touches playback, the media session, the notification or the lock screen, and
neither revokes the system grant — that is the user's business and lives in
Android's own settings.

---

## Platform differences, stated plainly

`IslandCapability` is reported **by the platform**, not inferred from
`Platform.isAndroid`, because the answer is not a property of the OS family: on
Android it depends on a grant the user controls, and on iOS it depends on
whether the build ships a Live Activity extension. Settings renders from that
report, so it can never offer a switch for something that will not appear.

| Platform | Floating surface | Reported as |
| --- | --- | --- |
| Android 6+ with the grant | overlay window | `overlayWindow`, `granted: true` |
| Android 6+ without it | one tap away | `overlayWindow`, `overlayPermissionMissing` |
| iOS 16.1+, no extension | none in this build | `none`, `liveActivityExtensionMissing` |
| iOS 16.1+, extension added | Live Activity | `liveActivity` |
| iOS ≤16.0, web, desktop | none | `none`, `unsupportedPlatform` |

**There is no iOS equivalent of the Android overlay and there cannot be** — an
iOS app cannot draw over other apps at all. The real iOS Dynamic Island is a
Live Activity, whose UI must live in a WidgetKit extension target; adding one is
an Xcode project change rather than a source change, so the source is written and
staged in [`ios/LiveActivity/`](../ios/LiveActivity/) and
`DynamicIslandChannel.capability()` reports the extension missing until it is
added. iOS users have the Lock Screen and Control Centre now, driven by the same
`PlayerController` as everything else.

---

## The minimise sequence, step by step

Run on a physical Android device with Spotify installed and a Premium account
signed in. `adb logcat -s flutter` shows the `island`, `playback` and
`media_session` scopes.

| # | Do this | Expect |
| --- | --- | --- |
| 1 | Open AURIX | Signed in, home feed |
| 2 | Settings → Appearance → Dynamic Island → **on** | Row reads ON; a second row appears |
| 3 | Tap **Keep it visible outside AURIX** | Dialog explaining "Display over other apps" |
| 4 | Confirm → grant → return | Snackbar: island will follow you out |
| 5 | Play **Song A** | Notification permission dialog (first run only); Song A plays through Spotify |
| 6 | Look at the top of AURIX | In-app pill shows Song A, cover, live equaliser |
| 7 | Press **Home** | `AURIX backgrounded` → `Floating island shown` |
| 8 | Look at the screen | Floating capsule with Song A's cover, title and play/pause |
| 9 | Pull down the shade | Media notification with Song A, artwork, transport |
| 10 | Change to **Song B** in the Spotify app | Capsule switches to Song B **within a second** |
| 11 | Check the cover | Artwork changes; it never shows Song A's cover under Song B's title |
| 12 | Watch the hairline | Progress advances; it reset on the track change |
| 13 | Tap **pause** on the capsule | Spotify pauses; the glyph becomes ▶; the notification agrees |
| 14 | Tap **play** | Spotify resumes; the glyph becomes ‖; progress moves again |
| 15 | Tap the capsule | Expands: artist line, progress, prev/play/next |
| 16 | Drag the capsule | It moves and stays where you left it |
| 17 | Lock the screen | Lock-screen controls show Song B with artwork and transport |
| 18 | Unlock, tap the capsule's artwork | AURIX comes forward on the player screen |
| 19 | Compare | Flutter UI and the notification show the same track, state and position |
| 20 | Note the top of the app | Floating capsule gone, in-app pill back — one island, not two |
| 21 | Settings → Dynamic Island → **off** | Both islands gone; **music keeps playing**; notification and lock screen intact |

### The things most likely to be wrong

- **Nothing floats after step 7.** Check the grant in Android Settings → Apps →
  AURIX → Display over other apps. The log line is `Floating island refused`.
- **No notification.** Two candidates, in order. `POST_NOTIFICATIONS` was refused
  — Android will not show the dialog again, so Settings → Apps → AURIX →
  Notifications. Or the platform rejected the session, in which case
  `adb logcat -s flutter | grep media_session` carries the reason: every
  `audio_service` publish failure is logged there and only there.
- **The notification appeared and then stopped coming back after a pause.** The
  foreground-service transition that used to cause this is gone — see "the
  service stays foreground across a pause" above. If it recurs, the log line to
  look for is a `ForegroundServiceStartNotAllowedException` in the same scope.
- **Capsule shows the previous song.** Should be impossible: `_reconcile`
  compares by `trackId` and `render()` clears the cover before loading a new one.
  If it happens, the App Remote push did not arrive — check the `playback` scope
  for `Track changed`.
- **Progress frozen while backgrounded.** The overlay's own handler stops when
  `playing` is false. Confirm the last `syncPosition` carried `playing: true`.
- **Two islands at once.** `appVisibilityProvider` did not fire. It is the only
  lifecycle listener in the app; check nothing else added one.

---

## What is deliberately not here

- **A second playback engine.** The island cannot start audio. Its buttons emit
  a command and wait; if Dart never answers, it keeps showing the last thing it
  was told — the correct failure mode for a remote control and an impossible one
  for a player.
- **An always-running service.** The media service starts with playback and
  stops with it. The overlay window is not a service at all.
- **A background position poll.** Backgrounded, App Remote is read once every
  five seconds over local IPC. Connect — which has no push channel — drops to
  once every fifteen.
- **An automatic permission request.** Neither grant is asked for by anything
  except the moment it is genuinely needed, and the overlay one only after the
  user has read a sentence about it.
