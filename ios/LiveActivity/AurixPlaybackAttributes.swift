import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// The contract between AURIX and its Live Activity.
///
/// **This file must be a member of two targets: `Runner` and the widget
/// extension.** That is not a convention — ActivityKit encodes and decodes the
/// state across a process boundary, so the app and the extension have to be
/// compiled against the same type. Adding it to only one is the single most
/// common reason a Live Activity builds and then never appears.
///
/// ## Why the shape matches Android's frame
///
/// The Dart side publishes one `IslandFrame` to whichever surface the platform
/// owns (see `lib/playback/background_island_channel.dart`). Keeping the fields
/// identical here means the two platforms consume the same payload rather than
/// each inventing a dialect, and the Dart controller stays platform-agnostic.
///
/// ## Position is an anchor, not a clock
///
/// `positionMs` is Spotify's own reported position and `anchoredAt` is when it
/// was reported. The Live Activity view interpolates between anchors with
/// `Text(timerInterval:)`, which the system animates without the app running —
/// which is the entire reason a Live Activity can show a moving timeline while
/// AURIX is suspended. Pushing a position every second instead would burn the
/// activity's update budget and get the app throttled.
@available(iOS 16.1, *)
struct AurixPlaybackAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// The track's Spotify id, so the view can tell a metadata update from a
    /// genuine track change and animate accordingly.
    var trackId: String
    var title: String
    var artist: String
    var album: String?

    /// Spotify CDN URL. WidgetKit cannot load a remote image, so the extension
    /// resolves this through a shared App Group container — see the README.
    var artworkUrl: String?

    var playing: Bool

    /// Spotify's reported position, and when it was reported.
    var positionMs: Int
    var anchoredAt: Date

    var durationMs: Int

    /// Where the timeline would be right now, projected from the anchor.
    /// Mirrors `projectedPositionMs` in the Android overlay exactly.
    var projectedPositionMs: Int {
      guard playing else { return positionMs }
      let elapsed = Int(Date().timeIntervalSince(anchoredAt) * 1000)
      return min(positionMs + elapsed, durationMs)
    }
  }

  /// Constant for the life of the activity. AURIX starts one activity per
  /// listening session and updates its `ContentState` as tracks change, rather
  /// than ending and requesting a new activity per song — the latter is visibly
  /// slower and burns the system's per-app activity budget.
  var sessionId: String
}
#endif
