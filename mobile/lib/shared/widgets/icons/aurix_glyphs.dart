import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'aurix_icon_geometry.dart';

/// The AURIX icon set.
///
/// Every glyph is drawn on [IconGrid]'s 24×24 canvas from the shared
/// primitives, so the whole set carries one stroke weight, one terminal style
/// and one optical size. Nothing here is a repackaged Material path.
///
/// Names describe the *role*, not the picture — `AurixGlyph.back` rather than
/// `arrowLeft` — so a later redraw does not leave every call site named after
/// a shape the icon no longer has.
enum AurixGlyph {
  // ---- Navigation -------------------------------------------------------
  home,
  search,
  searchActive,
  library,
  playlist,
  profile,
  settings,

  // ---- Chrome -----------------------------------------------------------
  back,
  close,
  chevronRight,
  chevronDown,
  more,
  moreVertical,
  add,
  check,
  checkCircle,
  notifications,
  sort,
  refresh,
  history,
  share,
  externalLink,
  dragHandle,
  trash,
  logout,

  // ---- Transport --------------------------------------------------------
  play,
  pause,
  skipNext,
  skipPrevious,
  shuffle,
  repeatAll,
  repeatOne,

  // ---- Music ------------------------------------------------------------
  musicNote,
  equalizer,
  album,
  artist,
  heart,
  heartFilled,

  // ---- Devices ----------------------------------------------------------
  devices,
  phone,
  speaker,

  // ---- Status -----------------------------------------------------------
  info,
  warning,
  offline,
  lock,
  mic,
  palette,
  motion,
  block,
  hourglass,

  // ---- Appearance -------------------------------------------------------
  moon,
  sun,
  auto,

  // ---- Browse categories ------------------------------------------------
  // The mood and genre tiles on Search. A fixed, known set — they come from a
  // switch over nine category ids, not from Spotify's taxonomy — so drawing
  // them is bounded work rather than an open-ended chase.
  leaf,
  dumbbell,
  target,
  bolt,
  piano,
  sparkle,

  // ---- Account & about --------------------------------------------------
  premium,
  terminal,
  mail,
  document,
  pin,
  trending,
  broom,

  // ---- Primitives -------------------------------------------------------
  // Deliberately shape-named rather than role-named: these *are* the shape.
  // A radio row wants an empty ring and a swatch wants a solid disc, and
  // neither has a better name than what it looks like.
  circle,
  dot,
  copy,
  explicit;

  /// Whether this glyph is a solid mark rather than an outline.
  ///
  /// Solid glyphs carry the accent fringe differently — a fringe behind a
  /// filled shape is hidden, so the painter offsets it outward instead.
  bool get isSolid =>
      this == AurixGlyph.play ||
      this == AurixGlyph.heartFilled ||
      this == AurixGlyph.skipNext ||
      this == AurixGlyph.skipPrevious;

  List<IconShape> build() => switch (this) {
    // ---- Navigation -----------------------------------------------------

    // A roof over a body, with the doorway opened into a web hub: two strands
    // meeting at the apex. It is the one place in the set where the web motif
    // is drawn into the glyph rather than layered behind it, because Home is
    // the mark users see most.
    AurixGlyph.home => [
      IconShape.stroke(
        iconPoly([
          const Offset(3.2, 11.4),
          const Offset(12, 4),
          const Offset(20.8, 11.4),
        ]),
      ),
      IconShape.stroke(
        iconPoly([
          const Offset(5.4, 9.6),
          const Offset(5.4, 20),
          const Offset(18.6, 20),
          const Offset(18.6, 9.6),
        ]),
      ),
      IconShape.stroke(iconLine(12, 6.4, 8.2, 20), weight: 0.5),
      IconShape.stroke(iconLine(12, 6.4, 15.8, 20), weight: 0.5),
      IconShape.stroke(iconArc(12, 6.4, 5.4, 35, 110), weight: 0.5),
    ],

    // A lens with two capture strands across it.
    AurixGlyph.search => [
      IconShape.stroke(iconCircle(10.6, 10.6, 6.2)),
      IconShape.stroke(iconLine(15.2, 15.2, 20.4, 20.4)),
      IconShape.stroke(iconArc(10.6, 10.6, 3.4, 200, 140), weight: 0.5),
    ],

    // The selected state of Search: the lens fills with a web hub.
    AurixGlyph.searchActive => [
      IconShape.stroke(iconCircle(10.6, 10.6, 6.2)),
      IconShape.stroke(iconLine(15.2, 15.2, 20.4, 20.4)),
      IconShape.stroke(iconLine(10.6, 4.4, 10.6, 16.8), weight: 0.5),
      IconShape.stroke(iconLine(4.4, 10.6, 16.8, 10.6), weight: 0.5),
      IconShape.stroke(iconArc(10.6, 10.6, 3.6, 0, 360), weight: 0.5),
    ],

    // Two upright spines and one leaning, with a note head resting against
    // them — books, and specifically books of music.
    AurixGlyph.library => [
      IconShape.stroke(iconLine(5.2, 4.6, 5.2, 19.6)),
      IconShape.stroke(iconLine(9.6, 4.6, 9.6, 19.6)),
      IconShape.stroke(iconLine(14, 5.6, 16.6, 19.4)),
      IconShape.fill(iconCircle(18.4, 17.6, 2.1)),
      IconShape.stroke(iconLine(20.5, 17.6, 20.5, 9.4)),
    ],

    // Three stacked strands with a note — the queue mark.
    AurixGlyph.playlist => [
      IconShape.stroke(iconLine(3.4, 6.6, 17.4, 6.6)),
      IconShape.stroke(iconLine(3.4, 11.4, 17.4, 11.4)),
      IconShape.stroke(iconLine(3.4, 16.2, 11, 16.2)),
      IconShape.fill(iconCircle(15.6, 18.4, 2.2)),
      IconShape.stroke(iconLine(17.8, 18.4, 17.8, 11.2)),
    ],

    // Head and shoulders. The head carries a single diagonal split — the
    // Miles nod, sized so it reads as a highlight rather than as a face.
    AurixGlyph.profile => [
      IconShape.stroke(iconCircle(12, 8.2, 4.2)),
      IconShape.stroke(iconArc(12, 21.4, 7.4, 200, 140)),
      IconShape.stroke(iconLine(9.1, 5.9, 14.4, 11), weight: 0.5),
    ],

    // A hub with radial teeth: a gear, and a web hub, and the same shape.
    AurixGlyph.settings => [
      IconShape.stroke(iconCircle(12, 12, 3.5)),
      IconShape.stroke(iconCircle(12, 12, 8.2), weight: 0.6),
      for (var i = 0; i < 8; i++)
        IconShape.stroke(_spoke(i * 45, 6.4, 9.4), weight: 0.9),
    ],

    // ---- Chrome ---------------------------------------------------------
    AurixGlyph.back => [
      IconShape.stroke(iconLine(20, 12, 5, 12)),
      IconShape.stroke(iconArrowHead(5, 12, 6, AxisDirection.left)),
    ],

    AurixGlyph.close => [
      IconShape.stroke(iconLine(6, 6, 18, 18)),
      IconShape.stroke(iconLine(18, 6, 6, 18)),
    ],

    AurixGlyph.chevronRight => [
      IconShape.stroke(iconChevron(11.5, 12, 5.4, AxisDirection.right)),
    ],

    AurixGlyph.chevronDown => [
      IconShape.stroke(iconChevron(12, 11.5, 5.4, AxisDirection.down)),
    ],

    AurixGlyph.more => [
      IconShape.stroke(iconDot(5.4, 12), weight: 1.35),
      IconShape.stroke(iconDot(12, 12), weight: 1.35),
      IconShape.stroke(iconDot(18.6, 12), weight: 1.35),
    ],

    AurixGlyph.moreVertical => [
      IconShape.stroke(iconDot(12, 5.4), weight: 1.35),
      IconShape.stroke(iconDot(12, 12), weight: 1.35),
      IconShape.stroke(iconDot(12, 18.6), weight: 1.35),
    ],

    // A plus whose quadrants carry four short strands — the comic "impact"
    // read, and the set's smallest use of the web motif.
    AurixGlyph.add => [
      IconShape.stroke(iconLine(12, 4.6, 12, 19.4)),
      IconShape.stroke(iconLine(4.6, 12, 19.4, 12)),
      for (var i = 0; i < 4; i++)
        IconShape.stroke(_spoke(45 + (i * 90), 6.2, 8.4), weight: 0.45),
    ],

    AurixGlyph.check => [
      IconShape.stroke(
        iconPoly([
          const Offset(4.8, 12.6),
          const Offset(9.8, 17.6),
          const Offset(19.2, 6.6),
        ]),
      ),
    ],

    AurixGlyph.checkCircle => [
      IconShape.stroke(iconCircle(12, 12, 8.6)),
      IconShape.stroke(
        iconPoly([
          const Offset(7.8, 12.2),
          const Offset(10.9, 15.4),
          const Offset(16.2, 8.8),
        ]),
        weight: 0.9,
      ),
    ],

    AurixGlyph.notifications => [
      IconShape.stroke(
        Path()
          ..moveTo(6.4, 17)
          ..lineTo(6.4, 11.6)
          ..arcToPoint(
            const Offset(17.6, 11.6),
            radius: const Radius.circular(5.6),
          )
          ..lineTo(17.6, 17),
      ),
      IconShape.stroke(iconLine(4.4, 17, 19.6, 17)),
      IconShape.stroke(iconArc(12, 17.8, 2.4, 20, 140), weight: 0.85),
    ],

    AurixGlyph.sort => [
      IconShape.stroke(iconLine(8, 4.8, 8, 19.2)),
      IconShape.stroke(iconArrowHead(8, 19.2, 3.2, AxisDirection.down)),
      IconShape.stroke(iconLine(16, 19.2, 16, 4.8)),
      IconShape.stroke(iconArrowHead(16, 4.8, 3.2, AxisDirection.up)),
    ],

    AurixGlyph.refresh => [
      IconShape.stroke(iconArc(12, 12, 7.4, 300, 300)),
      IconShape.stroke(iconArrowHead(15.7, 5.6, 3.4, AxisDirection.up)),
    ],

    AurixGlyph.history => [
      IconShape.stroke(iconArc(12, 12, 7.8, 300, 300)),
      IconShape.stroke(iconArrowHead(8.3, 5.6, 3.4, AxisDirection.up)),
      IconShape.stroke(
        iconPoly([const Offset(12, 7.8), const Offset(12, 12), const Offset(15.6, 13.8)]),
        weight: 0.9,
      ),
    ],

    // Three nodes and the strands between them.
    AurixGlyph.share => [
      IconShape.stroke(iconCircle(17.6, 5.6, 2.9)),
      IconShape.stroke(iconCircle(6.4, 12, 2.9)),
      IconShape.stroke(iconCircle(17.6, 18.4, 2.9)),
      IconShape.stroke(iconLine(9, 10.6, 15.1, 7), weight: 0.8),
      IconShape.stroke(iconLine(9, 13.4, 15.1, 17), weight: 0.8),
    ],

    AurixGlyph.externalLink => [
      IconShape.stroke(
        iconPoly([
          const Offset(12.6, 5.4),
          const Offset(5.4, 5.4),
          const Offset(5.4, 18.6),
          const Offset(18.6, 18.6),
          const Offset(18.6, 11.4),
        ]),
      ),
      IconShape.stroke(iconLine(11.2, 12.8, 18.6, 5.4)),
      IconShape.stroke(iconArrowHead(18.6, 5.4, 4.4, AxisDirection.up)),
    ],

    AurixGlyph.dragHandle => [
      IconShape.stroke(iconLine(5.4, 9.6, 18.6, 9.6)),
      IconShape.stroke(iconLine(5.4, 14.4, 18.6, 14.4)),
    ],

    AurixGlyph.trash => [
      IconShape.stroke(iconLine(4.6, 6.8, 19.4, 6.8)),
      IconShape.stroke(
        iconPoly([
          const Offset(9.4, 6.8),
          const Offset(9.4, 4.6),
          const Offset(14.6, 4.6),
          const Offset(14.6, 6.8),
        ]),
        weight: 0.85,
      ),
      IconShape.stroke(
        iconPoly([
          const Offset(6.6, 6.8),
          const Offset(7.6, 19.4),
          const Offset(16.4, 19.4),
          const Offset(17.4, 6.8),
        ]),
      ),
    ],

    AurixGlyph.logout => [
      IconShape.stroke(
        iconPoly([
          const Offset(12.6, 4.6),
          const Offset(4.8, 4.6),
          const Offset(4.8, 19.4),
          const Offset(12.6, 19.4),
        ]),
      ),
      IconShape.stroke(iconLine(9.6, 12, 19.4, 12)),
      IconShape.stroke(iconArrowHead(19.4, 12, 3.6, AxisDirection.right)),
    ],

    // ---- Transport ------------------------------------------------------
    AurixGlyph.play => [IconShape.fill(iconTriangle(12.6, 12, 7.4))],

    AurixGlyph.pause => [
      IconShape.stroke(iconLine(8.8, 5.4, 8.8, 18.6), weight: 1.9),
      IconShape.stroke(iconLine(15.2, 5.4, 15.2, 18.6), weight: 1.9),
    ],

    AurixGlyph.skipNext => [
      IconShape.fill(iconTriangle(9.4, 12, 6.4)),
      IconShape.stroke(iconLine(17.4, 5.8, 17.4, 18.2), weight: 1.5),
    ],

    // Mirrored from [skipNext] wholesale rather than redrawn. `iconTriangle`
    // is deliberately not symmetric about its centre — the tip reaches further
    // than the back edge — so mirroring the triangle alone and then placing
    // the bar by hand put the bar *inside* the triangle. Reflecting the whole
    // composition makes the pair exact by construction.
    AurixGlyph.skipPrevious => _mirrorShapes(AurixGlyph.skipNext.build()),

    AurixGlyph.shuffle => [
      IconShape.stroke(
        Path()
          ..moveTo(3.6, 7)
          ..lineTo(7.4, 7)
          ..cubicTo(11, 7, 13, 17, 16.6, 17)
          ..lineTo(19.4, 17),
      ),
      IconShape.stroke(
        Path()
          ..moveTo(3.6, 17)
          ..lineTo(7.4, 17)
          ..cubicTo(11, 17, 13, 7, 16.6, 7)
          ..lineTo(19.4, 7),
      ),
      IconShape.stroke(iconArrowHead(19.4, 7, 3, AxisDirection.right)),
      IconShape.stroke(iconArrowHead(19.4, 17, 3, AxisDirection.right)),
    ],

    AurixGlyph.repeatAll => [
      IconShape.stroke(iconRRect(4.4, 6.2, 19.6, 17.8, radius: 4.6)),
      IconShape.stroke(iconArrowHead(13.4, 6.2, 3, AxisDirection.right)),
    ],

    AurixGlyph.repeatOne => [
      IconShape.stroke(iconRRect(4.4, 6.2, 19.6, 17.8, radius: 4.6)),
      IconShape.stroke(iconArrowHead(13.4, 6.2, 3, AxisDirection.right)),
      IconShape.stroke(
        iconPoly([const Offset(10.6, 11), const Offset(12, 9.8), const Offset(12, 14.6)]),
        weight: 0.8,
      ),
    ],

    // ---- Music ----------------------------------------------------------
    AurixGlyph.musicNote => iconNote(headX: 9, headY: 17.4, stemHeight: 11.2),

    AurixGlyph.equalizer => [
      IconShape.stroke(iconLine(5.6, 15.4, 5.6, 19.4), weight: 1.5),
      IconShape.stroke(iconLine(9.9, 9.4, 9.9, 19.4), weight: 1.5),
      IconShape.stroke(iconLine(14.1, 4.6, 14.1, 19.4), weight: 1.5),
      IconShape.stroke(iconLine(18.4, 12.4, 18.4, 19.4), weight: 1.5),
    ],

    AurixGlyph.album => [
      IconShape.stroke(iconCircle(12, 12, 8.6)),
      IconShape.stroke(iconCircle(12, 12, 2.4), weight: 0.9),
      IconShape.stroke(iconArc(12, 12, 5.5, 210, 120), weight: 0.5),
    ],

    AurixGlyph.artist => [
      IconShape.stroke(iconCircle(12, 7.6, 3.8)),
      IconShape.stroke(iconArc(12, 20.6, 6.8, 200, 140)),
      IconShape.stroke(iconArc(12, 7.6, 6.4, 195, 150), weight: 0.45),
    ],

    AurixGlyph.heart => [IconShape.stroke(_heartPath())],
    AurixGlyph.heartFilled => [IconShape.fill(_heartPath())],

    // ---- Devices --------------------------------------------------------
    AurixGlyph.devices => [
      IconShape.stroke(iconRRect(2.6, 5.4, 14.4, 14, radius: 1.8)),
      IconShape.stroke(iconLine(5.4, 17.4, 11.6, 17.4), weight: 0.9),
      IconShape.stroke(iconRRect(16.2, 9.4, 21.4, 18.6, radius: 1.6)),
    ],

    AurixGlyph.phone => [
      IconShape.stroke(iconRRect(6.6, 3.4, 17.4, 20.6, radius: 2.6)),
      IconShape.stroke(iconLine(10.4, 6.6, 13.6, 6.6), weight: 0.8),
      IconShape.stroke(iconDot(12, 17.4), weight: 0.9),
    ],

    AurixGlyph.speaker => [
      IconShape.stroke(iconRRect(5.6, 2.8, 18.4, 21.2, radius: 2.6)),
      IconShape.stroke(iconCircle(12, 14.6, 3.9), weight: 0.9),
      IconShape.stroke(iconDot(12, 7), weight: 0.9),
    ],

    // ---- Status ---------------------------------------------------------
    AurixGlyph.info => [
      IconShape.stroke(iconCircle(12, 12, 8.6)),
      IconShape.stroke(iconLine(12, 11.2, 12, 16.4), weight: 0.95),
      IconShape.stroke(iconDot(12, 7.8), weight: 0.95),
    ],

    AurixGlyph.warning => [
      IconShape.stroke(
        iconPoly([
          const Offset(12, 4),
          const Offset(21, 19.6),
          const Offset(3, 19.6),
        ], close: true),
      ),
      IconShape.stroke(iconLine(12, 10.2, 12, 14.4), weight: 0.95),
      IconShape.stroke(iconDot(12, 17.2), weight: 0.95),
    ],

    AurixGlyph.offline => [
      IconShape.stroke(iconArc(12, 13.6, 7.6, 195, 150)),
      IconShape.stroke(iconArc(12, 13.6, 4.2, 195, 150), weight: 0.8),
      IconShape.stroke(iconLine(4.6, 4.6, 19.4, 19.4)),
    ],

    AurixGlyph.lock => [
      IconShape.stroke(iconRRect(4.8, 10.6, 19.2, 20.4, radius: 2.4)),
      IconShape.stroke(iconArc(12, 10.6, 4.6, 180, 180)),
      IconShape.stroke(iconDot(12, 15.4), weight: 1.1),
    ],

    AurixGlyph.mic => [
      IconShape.stroke(iconRRect(9, 3.2, 15, 14, radius: 3)),
      IconShape.stroke(iconArc(12, 12.4, 5.6, 0, 180)),
      IconShape.stroke(iconLine(12, 18, 12, 20.8)),
    ],

    AurixGlyph.palette => [
      IconShape.stroke(iconCircle(12, 12, 8.6)),
      IconShape.stroke(iconDot(9, 9.2), weight: 1.15),
      IconShape.stroke(iconDot(15, 9.2), weight: 1.15),
      IconShape.stroke(iconDot(9, 14.8), weight: 1.15),
      IconShape.stroke(iconDot(15, 14.8), weight: 1.15),
    ],

    // Motion: a mark with speed lines trailing it.
    AurixGlyph.motion => [
      IconShape.fill(iconCircle(16.4, 12, 3.2)),
      IconShape.stroke(iconLine(3.4, 7.4, 10.6, 7.4), weight: 0.9),
      IconShape.stroke(iconLine(2.6, 12, 11, 12), weight: 0.9),
      IconShape.stroke(iconLine(4.2, 16.6, 10.6, 16.6), weight: 0.9),
    ],

    AurixGlyph.block => [
      IconShape.stroke(iconCircle(12, 12, 8.4)),
      IconShape.stroke(iconLine(6.1, 6.1, 17.9, 17.9)),
    ],

    AurixGlyph.hourglass => [
      IconShape.stroke(iconLine(6.2, 4.2, 17.8, 4.2)),
      IconShape.stroke(iconLine(6.2, 19.8, 17.8, 19.8)),
      IconShape.stroke(
        iconPoly([
          const Offset(7.8, 4.2),
          const Offset(7.8, 8.4),
          const Offset(12, 12),
          const Offset(16.2, 8.4),
          const Offset(16.2, 4.2),
        ]),
        weight: 0.9,
      ),
      IconShape.stroke(
        iconPoly([
          const Offset(7.8, 19.8),
          const Offset(7.8, 15.6),
          const Offset(12, 12),
          const Offset(16.2, 15.6),
          const Offset(16.2, 19.8),
        ]),
        weight: 0.9,
      ),
    ],

    // ---- Appearance -----------------------------------------------------

    // A disc with a bite taken out of it. Built with a boolean difference
    // rather than by hand-fitting two arcs — a crescent assembled from
    // `arcToPoint` calls is almost impossible to verify without rendering it,
    // and gets subtly wrong tips.
    AurixGlyph.moon => [
      IconShape.fill(
        Path.combine(
          PathOperation.difference,
          iconCircle(12, 12, 8.4),
          iconCircle(16.4, 8.2, 7.6),
        ),
      ),
    ],

    AurixGlyph.sun => [
      IconShape.fill(iconCircle(12, 12, 4.3)),
      for (var i = 0; i < 8; i++)
        IconShape.stroke(_spoke(i * 45, 6.8, 9.6), weight: 0.9),
    ],

    // Half lit, half not — the "match the system" mark.
    AurixGlyph.auto => [
      IconShape.stroke(iconCircle(12, 12, 8.4)),
      IconShape.fill(
        Path.combine(
          PathOperation.intersect,
          iconCircle(12, 12, 8.4),
          Path()..addRect(const Rect.fromLTRB(12, 3.6, 20.4, 20.4)),
        ),
      ),
    ],

    // ---- Browse categories ----------------------------------------------
    AurixGlyph.leaf => [
      IconShape.stroke(
        Path()
          ..moveTo(4.8, 19.2)
          ..cubicTo(4.2, 10.4, 10.4, 4.4, 19.4, 4.8)
          ..cubicTo(19.8, 13.6, 13.6, 19.6, 4.8, 19.2)
          ..close(),
      ),
      IconShape.stroke(iconLine(4.8, 19.2, 15.4, 8.6), weight: 0.6),
    ],

    AurixGlyph.dumbbell => [
      IconShape.stroke(iconLine(8.6, 12, 15.4, 12), weight: 0.9),
      IconShape.stroke(iconLine(7.2, 7.8, 7.2, 16.2), weight: 1.5),
      IconShape.stroke(iconLine(16.8, 7.8, 16.8, 16.2), weight: 1.5),
      IconShape.stroke(iconLine(3.6, 9.8, 3.6, 14.2), weight: 1.1),
      IconShape.stroke(iconLine(20.4, 9.8, 20.4, 14.2), weight: 1.1),
    ],

    AurixGlyph.target => [
      IconShape.stroke(iconCircle(12, 12, 8.4)),
      IconShape.stroke(iconCircle(12, 12, 4.6), weight: 0.8),
      IconShape.fill(iconCircle(12, 12, 1.5)),
    ],

    AurixGlyph.bolt => [
      IconShape.fill(
        iconPoly([
          const Offset(13.8, 2.8),
          const Offset(6.4, 13.4),
          const Offset(11.2, 13.4),
          const Offset(10.2, 21.2),
          const Offset(17.6, 10.6),
          const Offset(12.8, 10.6),
        ], close: true),
      ),
    ],

    AurixGlyph.piano => [
      IconShape.stroke(iconRRect(3.4, 6.6, 20.6, 17.4, radius: 2)),
      IconShape.stroke(iconLine(9.1, 6.6, 9.1, 17.4), weight: 0.6),
      IconShape.stroke(iconLine(14.9, 6.6, 14.9, 17.4), weight: 0.6),
      IconShape.stroke(iconLine(7, 6.6, 7, 12.6), weight: 1.3),
      IconShape.stroke(iconLine(12, 6.6, 12, 12.6), weight: 1.3),
      IconShape.stroke(iconLine(17, 6.6, 17, 12.6), weight: 1.3),
    ],

    // A four-point star with a smaller companion — the "something new" mark.
    AurixGlyph.sparkle => [
      IconShape.fill(_star(10, 10.4, 7.4)),
      IconShape.fill(_star(18.2, 18, 3.6)),
    ],

    // ---- Account & about ------------------------------------------------
    AurixGlyph.premium => [
      IconShape.stroke(
        iconPoly([
          const Offset(12, 3),
          const Offset(20.4, 8.2),
          const Offset(18.2, 18.4),
          const Offset(5.8, 18.4),
          const Offset(3.6, 8.2),
        ], close: true),
      ),
      IconShape.fill(_star(12, 11.4, 4.4)),
    ],

    AurixGlyph.terminal => [
      IconShape.stroke(iconRRect(3.2, 4.6, 20.8, 19.4, radius: 2.4)),
      IconShape.stroke(
        iconPoly([
          const Offset(7.4, 10),
          const Offset(10.6, 12.6),
          const Offset(7.4, 15.2),
        ]),
        weight: 0.85,
      ),
      IconShape.stroke(iconLine(13, 15.2, 16.8, 15.2), weight: 0.85),
    ],

    AurixGlyph.mail => [
      IconShape.stroke(iconRRect(3, 5.4, 21, 18.6, radius: 2.4)),
      IconShape.stroke(
        iconPoly([
          const Offset(4.4, 7.2),
          const Offset(12, 13),
          const Offset(19.6, 7.2),
        ]),
        weight: 0.85,
      ),
    ],

    AurixGlyph.document => [
      IconShape.stroke(
        iconPoly([
          const Offset(13.6, 3.4),
          const Offset(5.4, 3.4),
          const Offset(5.4, 20.6),
          const Offset(18.6, 20.6),
          const Offset(18.6, 8.4),
        ], close: true),
      ),
      IconShape.stroke(
        iconPoly([const Offset(13.6, 3.4), const Offset(18.6, 8.4)]),
        weight: 0.7,
      ),
      IconShape.stroke(iconLine(8.6, 12.6, 15.4, 12.6), weight: 0.7),
      IconShape.stroke(iconLine(8.6, 16.2, 15.4, 16.2), weight: 0.7),
    ],

    AurixGlyph.pin => [
      IconShape.stroke(iconCircle(12, 9, 4.2)),
      IconShape.stroke(iconLine(12, 13.2, 12, 20.8)),
    ],

    AurixGlyph.trending => [
      IconShape.stroke(
        iconPoly([
          const Offset(3.6, 16.8),
          const Offset(9.4, 11),
          const Offset(13.2, 14.8),
          const Offset(20.4, 7.6),
        ]),
      ),
      IconShape.stroke(
        iconPoly([const Offset(14.8, 7.6), const Offset(20.4, 7.6), const Offset(20.4, 13.2)]),
        weight: 0.85,
      ),
    ],

    AurixGlyph.circle => [IconShape.stroke(iconCircle(12, 12, 8.4))],

    AurixGlyph.dot => [IconShape.fill(iconCircle(12, 12, 7.4))],

    AurixGlyph.copy => [
      IconShape.stroke(iconRRect(8.4, 3.4, 20.6, 15.6, radius: 2.4)),
      IconShape.stroke(
        iconPoly([
          const Offset(15.6, 18.4),
          const Offset(15.6, 20.6),
          const Offset(3.4, 20.6),
          const Offset(3.4, 8.4),
          const Offset(5.6, 8.4),
        ]),
        weight: 0.85,
      ),
    ],

    // The "E" marker Spotify requires beside explicit content.
    AurixGlyph.explicit => [
      IconShape.stroke(iconRRect(3.6, 3.6, 20.4, 20.4, radius: 3.4)),
      IconShape.stroke(iconLine(9, 7.6, 15.4, 7.6), weight: 0.85),
      IconShape.stroke(iconLine(9, 12, 14.2, 12), weight: 0.85),
      IconShape.stroke(iconLine(9, 16.4, 15.4, 16.4), weight: 0.85),
      IconShape.stroke(iconLine(9, 7.6, 9, 16.4), weight: 0.85),
    ],

    AurixGlyph.broom => [
      IconShape.stroke(iconLine(17.6, 4.4, 10.4, 11.6)),
      IconShape.stroke(
        iconPoly([
          const Offset(6.2, 13.6),
          const Offset(12.4, 9.4),
          const Offset(17, 15.6),
          const Offset(9.8, 19.6),
        ], close: true),
      ),
      IconShape.stroke(iconLine(9.2, 11.8, 13.4, 17.6), weight: 0.5),
    ],
  };
}

/// A four-point star: two crossed spikes with concave waists.
///
/// Shared by [AurixGlyph.sparkle] and [AurixGlyph.premium] so the two cannot
/// drift into different star shapes.
Path _star(double cx, double cy, double reach) {
  final waist = reach * 0.28;
  return Path()
    ..moveTo(cx, cy - reach)
    ..quadraticBezierTo(cx + waist, cy - waist, cx + reach, cy)
    ..quadraticBezierTo(cx + waist, cy + waist, cx, cy + reach)
    ..quadraticBezierTo(cx - waist, cy + waist, cx - reach, cy)
    ..quadraticBezierTo(cx - waist, cy - waist, cx, cy - reach)
    ..close();
}

/// A radial tick from [inner] to [outer] at [degrees], about the grid centre.
///
/// Used by the gear and the plus. Both are web hubs wearing different clothes,
/// which is the point — the motif recurs rather than being restated.
Path _spoke(double degrees, double inner, double outer) {
  final radians = degrees * math.pi / 180;
  final dx = math.cos(radians);
  final dy = math.sin(radians);
  return iconLine(
    IconGrid.centre.dx + (dx * inner),
    IconGrid.centre.dy + (dy * inner),
    IconGrid.centre.dx + (dx * outer),
    IconGrid.centre.dy + (dy * outer),
  );
}

/// Mirrors a path about the grid's vertical centre line.
Path _mirrored(Path path) => path.transform(
  (Matrix4.identity()
        ..translateByDouble(IconGrid.size, 0, 0, 1)
        ..scaleByDouble(-1, 1, 1, 1))
      .storage,
);

/// Reflects a whole glyph, preserving each shape's fill mode and weight.
List<IconShape> _mirrorShapes(List<IconShape> shapes) => <IconShape>[
  for (final shape in shapes)
    if (shape.filled)
      IconShape.fill(_mirrored(shape.path))
    else
      IconShape.stroke(_mirrored(shape.path), weight: shape.weight),
];

/// Two lobes meeting at a point. Drawn once and shared by the outline and
/// filled hearts so the two can never drift apart.
Path _heartPath() => Path()
  ..moveTo(12, 20.2)
  ..cubicTo(4.2, 15.4, 3, 11.6, 3.9, 8.9)
  ..cubicTo(5, 5.6, 9.6, 4.6, 12, 8.2)
  ..cubicTo(14.4, 4.6, 19, 5.6, 20.1, 8.9)
  ..cubicTo(21, 11.6, 19.8, 15.4, 12, 20.2)
  ..close();
