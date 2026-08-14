import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

/// AURIX's Live Activity — the real iOS Dynamic Island.
///
/// **This file belongs to the widget extension target only**, unlike
/// `AurixPlaybackAttributes.swift` which belongs to both.
///
/// ## The four presentations
///
/// One activity, rendered four ways by the system, and every one of them has to
/// stand on its own:
///
///  * **Lock Screen / banner** — the full card.
///  * **Expanded** — the Dynamic Island opened by a long press.
///  * **Compact leading / trailing** — the two slivers either side of the
///    cutout, roughly 40pt wide each. Artwork on one side, a play state on the
///    other; anything more is illegible.
///  * **Minimal** — one glyph, when another app is also running an activity.
///
/// ## What it cannot do
///
/// A Live Activity view is a WidgetKit view. It cannot run code, cannot make
/// network requests, and cannot load a remote image — so the artwork comes from
/// a file the app has already written into a shared App Group container, and
/// the timeline is a `Text(timerInterval:)` the system animates on its own.
/// Both constraints are why the state pushed from Dart is an *anchor* rather
/// than a stream of positions.
@available(iOS 16.1, *)
struct AurixIslandWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AurixPlaybackAttributes.self) { context in
      LockScreenCard(state: context.state)
        .activityBackgroundTint(Color.black.opacity(0.92))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Artwork(state: context.state, size: 42)
        }
        DynamicIslandExpandedRegion(.trailing) {
          PlayStateGlyph(playing: context.state.playing)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.state.title)
              .font(.system(size: 14, weight: .semibold))
              .lineLimit(1)
            Text(context.state.artist)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          Timeline(state: context.state)
        }
      } compactLeading: {
        Artwork(state: context.state, size: 20)
      } compactTrailing: {
        PlayStateGlyph(playing: context.state.playing)
      } minimal: {
        PlayStateGlyph(playing: context.state.playing)
      }
      .keylineTint(.white)
    }
  }
}

@available(iOS 16.1, *)
private struct LockScreenCard: View {
  let state: AurixPlaybackAttributes.ContentState

  var body: some View {
    HStack(spacing: 12) {
      Artwork(state: state, size: 48)
      VStack(alignment: .leading, spacing: 3) {
        Text(state.title)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
        Text(state.artist)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Timeline(state: state)
      }
      PlayStateGlyph(playing: state.playing)
    }
    .padding(14)
  }
}

/// The moving timeline.
///
/// `ProgressView(timerInterval:)` is animated by the system from a start and an
/// end date, with no process of AURIX's running. That is the only way a Live
/// Activity shows a scrubber that moves: an activity may be updated a limited
/// number of times per hour, so a position push per second would be throttled
/// into a frozen bar within minutes.
///
/// Paused, it falls back to a static bar at the anchored position — a paused
/// timer interval would still count down.
@available(iOS 16.1, *)
private struct Timeline: View {
  let state: AurixPlaybackAttributes.ContentState

  var body: some View {
    if state.playing, state.durationMs > 0 {
      let remaining = Double(state.durationMs - state.projectedPositionMs) / 1000
      ProgressView(
        timerInterval: Date()...Date().addingTimeInterval(max(remaining, 1)),
        countsDown: false
      )
      .progressViewStyle(.linear)
      .tint(.white)
    } else {
      ProgressView(
        value: Double(state.projectedPositionMs),
        total: Double(max(state.durationMs, 1))
      )
      .progressViewStyle(.linear)
      .tint(.white.opacity(0.6))
    }
  }
}

/// Album art, read from the shared App Group container.
///
/// WidgetKit cannot fetch a URL, so the app writes the decoded cover to the
/// container as `artwork-<trackId>.jpg` before it updates the activity. A
/// missing file draws the empty tile rather than the previous song's cover —
/// the same rule the Android overlay follows, and for the same reason.
@available(iOS 16.1, *)
private struct Artwork: View {
  let state: AurixPlaybackAttributes.ContentState
  let size: CGFloat

  var body: some View {
    Group {
      if let image = loadImage() {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Color.white.opacity(0.08)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
  }

  private func loadImage() -> UIImage? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: AurixLiveActivity.appGroup
      )
    else { return nil }
    let url = container.appendingPathComponent("artwork-\(state.trackId).jpg")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return UIImage(data: data)
  }
}

@available(iOS 16.1, *)
private struct PlayStateGlyph: View {
  let playing: Bool

  var body: some View {
    Image(systemName: playing ? "waveform" : "pause.fill")
      .foregroundStyle(.white)
      .symbolEffect(.variableColor, isActive: playing)
  }
}

/// Shared constants. Duplicated deliberately in the extension rather than
/// imported: an extension cannot import the app target, and an App Group id is
/// a string both sides must agree on.
enum AurixLiveActivity {
  /// Must match the App Group added to **both** targets in Signing &
  /// Capabilities, and the value used by the app when it writes artwork.
  static let appGroup = "group.com.aurix.app"
}

@main
struct AurixIslandBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOS 16.1, *) {
      AurixIslandWidget()
    }
  }
}
#endif
