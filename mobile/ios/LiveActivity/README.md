# AURIX Live Activity (iOS Dynamic Island)

This folder holds the source for AURIX's iOS Live Activity. **It is not part of
the build yet**, and the app is honest about that at runtime: with no extension
linked, `DynamicIslandChannel.capability()` in `ios/Runner/AppDelegate.swift`
reports `liveActivityExtensionMissing`, the Dart controller never tries to draw
one, and the Settings screen says the island stays inside AURIX on this device.

## Why it is not wired up

A Live Activity's UI is a WidgetKit view, and a WidgetKit view has to live in a
**widget extension target**. Adding a target is a change to
`Runner.xcodeproj/project.pbxproj`, not a change to any source file, and it also
needs an App Group, two capability grants and a provisioning profile per target.
None of that can be produced correctly by editing text — it has to be done in
Xcode, once, by someone with the signing identity.

Everything that *can* be written ahead of time is written: the shared attributes
type, the four island presentations, and the capability reporting that flips to
`liveActivity` the moment the extension exists.

## What iOS users have in the meantime

Background playback and its system controls, which is the part that matters:

- `audio_service` owns the Now Playing session, so the **Lock Screen** and
  **Control Centre** show the current track, artist, artwork and transport
  controls while AURIX is backgrounded.
- Metadata is republished on every track change by `PlayerController`, so the
  lock screen never shows the previous song.
- The timeline is anchored from Spotify's reported position, so the scrubber
  matches what is actually playing.

What is missing without the extension is only the cutout presentation — the
floating pill outside the app. iOS offers no other mechanism for it: an app
cannot draw over other apps on iOS at all, so there is no Android-style overlay
fallback and this document does not pretend otherwise.

## Adding the extension

1. **Xcode → File → New → Target → Widget Extension.** Name it
   `AurixIslandWidget`. Tick *Include Live Activity*; leave *Include
   Configuration App Intent* off.

2. **Delete the generated placeholder sources** and add the two files here
   instead:

   | File | Targets |
   | --- | --- |
   | `AurixPlaybackAttributes.swift` | `Runner` **and** `AurixIslandWidget` |
   | `AurixIslandWidget.swift` | `AurixIslandWidget` only |

   The first one being a member of both targets is load-bearing — ActivityKit
   encodes the state across a process boundary, and a type compiled into only
   one side produces an activity that starts and never renders.

3. **Add an App Group** to both targets under *Signing & Capabilities*:
   `group.com.aurix.app`. It must match `AurixLiveActivity.appGroup` in
   `AurixIslandWidget.swift`. The extension cannot fetch a URL, so this is how
   the cover reaches it: the app writes the decoded artwork into the container
   as `artwork-<trackId>.jpg` before updating the activity.

4. **Add to `ios/Runner/Info.plist`:**

   ```xml
   <key>NSSupportsLiveActivities</key>
   <true/>
   ```

   Add `NSSupportsLiveActivitiesFrequentUpdates` only if you later decide to
   push positions more often than track changes — see the note on budgets below,
   which is the reason AURIX does not.

5. **Set the extension's deployment target to iOS 16.1** or later.

6. **Implement the ActivityKit calls** in `DynamicIslandChannel` in
   `AppDelegate.swift`. The Dart contract does not change — `capability`,
   `show`, `update`, `syncPosition` and `hide`, with the payload documented in
   `lib/playback/background_island_channel.dart`. Sketch:

   ```swift
   // show
   let attributes = AurixPlaybackAttributes(sessionId: UUID().uuidString)
   activity = try Activity.request(
     attributes: attributes,
     content: .init(state: state, staleDate: nil)
   )

   // update
   await activity?.update(.init(state: state, staleDate: nil))

   // hide
   await activity?.end(nil, dismissalPolicy: .immediate)
   ```

   Return `"granted": true` from `capability()` at the same commit, and not
   before — that flag is what makes the Dart controller start calling `show`.

## Design constraints worth keeping

- **Update budget.** iOS throttles Live Activity updates per app per hour. AURIX
  publishes on *change* — a track change, a play/pause, a seek — and lets the
  view animate the timeline itself with `Text(timerInterval:)` /
  `ProgressView(timerInterval:)`. Pushing a position every second would get the
  activity frozen within minutes, and it is exactly the "independent fake
  playback timer" the architecture forbids.

- **One activity per session, not per track.** Ending and re-requesting an
  activity on every song is visibly slower and consumes the per-app activity
  budget. Update the `ContentState` instead; `trackId` is in there so the view
  can tell a real track change from a metadata refresh.

- **Never leave the previous cover up.** `Artwork` draws the empty tile when the
  file for the current `trackId` is missing, rather than whatever was there
  before. Same rule as the Android overlay.
