// ignore_for_file: avoid_print — this is a command-line tool.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aurix/data/models/avatar.dart';

/// Renders the bundled AURIX profile avatars into `assets/avatars/`.
///
/// ```
/// dart run tool/generate_avatars.dart
/// ```
///
/// ## What these are
///
/// Sixteen illustrated character portraits — a figure with skin, hair, a face
/// and something worn: headphones, a visor, a cap, a hood, a mic boom. They are
/// profile *pictures*, which is the whole point. The set they replace was
/// twelve abstract geometric marks on a grey ramp: consistent, cheap, and the
/// wrong answer to "what does this person look like in AURIX".
///
/// Every portrait is an original construction of ellipses, capsules, arcs and
/// polygons defined in this file. Nothing is traced, photographed or derived
/// from an existing character, so there is no likeness and no third-party
/// artwork anywhere in the bundle.
///
/// ## Why they are generated rather than exported from a design tool
///
/// AURIX ships its own profile pictures because users cannot supply one — see
/// the rule stated in `lib/data/models/avatar.dart`. That makes the avatar set
/// part of the brand, and sixteen hand-exported files are sixteen chances for a
/// head to sit two pixels lower or a skin tone to drift half a step.
///
/// Here every portrait is built from one shared armature — the same head, neck,
/// shoulders, eye line and rim light — and differs only in hair, accessory and
/// palette. That is what makes sixteen different faces read as one set at
/// three-up in the picker, and it means the whole catalogue can be re-rendered
/// from source when a proportion or a colour changes.
///
/// ## Why they are in colour, when AURIX is not
///
/// The app has one accent and no hue to spend — see `AurixPalette`. A portrait
/// is the one place that rule has to give: skin has a colour, and a set of grey
/// faces would look like an error rather than a decision. So the colour is
/// spent deliberately and in a fixed structure — one saturated accent per
/// avatar, on a near-black ground, lighting the rim of the figure and one
/// object it is wearing. Dark, neon-lit, and at home in a dark music app.
///
/// ## The catalogue is in charge
///
/// [AvatarCatalog] decides how many avatars exist and what they are called;
/// this file only knows how to draw them. Add a name there and this script
/// stops with an explicit message until artwork for it is added to [_designs] —
/// so the catalogue can never name an asset that is missing from the bundle.
void main() {
  final root = Directory.current.path;

  if (_designs.length != AvatarCatalog.count) {
    print(
      'Design list is out of step with the catalogue.\n'
      '  AvatarCatalog.names holds ${AvatarCatalog.count} entries\n'
      '  tool/generate_avatars.dart holds ${_designs.length} designs\n'
      'Add or remove a portrait so the two match, then run this again.',
    );
    exitCode = 1;
    return;
  }

  var bytes = 0;
  for (var index = 0; index < AvatarCatalog.all.length; index++) {
    final avatar = AvatarCatalog.all[index];
    final png = _render(_designs[index](), _size);
    _write('$root/${avatar.assetPath}', png, avatar.name);
    bytes += png.length;
  }

  print(
    'Wrote ${AvatarCatalog.count} avatars '
    '(${(bytes / 1024).toStringAsFixed(0)} KB total).',
  );
}

void _write(String path, Uint8List png, String name) {
  final file = File(path)..parent.createSync(recursive: true);
  file.writeAsBytesSync(png);
  print('  ${path.split(RegExp(r'[\\/]')).last.padRight(18)}'
      '${name.padRight(12)}${(png.length / 1024).toStringAsFixed(1)} KB');
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

/// Rendered edge in pixels.
///
/// The largest place an avatar is drawn is the 96pt profile header, which is
/// 288px on a 3× screen. 320 covers that with a margin.
const int _size = 320;

/// Samples per axis. 16 per pixel — enough to keep a 0.05-unit eye clean at the
/// 30px library-header size, where the whole portrait is smaller than a
/// fingernail.
const int _ss = 4;

// Everything below is authored in *portrait units*: the tile is the square from
// (-1, -1) to (1, 1) with y pointing down, so the circular crop the UI applies
// is exactly the unit circle. Coordinates are chosen against that crop — the
// shoulders are wide enough to fill its lower wedge, and nothing that matters
// sits in a corner the crop removes.

// ---------------------------------------------------------------------------
// The armature — shared by all sixteen
// ---------------------------------------------------------------------------

const double _headCy = -0.03;
const double _headRx = 0.365;
const double _headRy = 0.445;

/// The head. Every other measurement is taken against this one.
const _S _head = _Ellipse(0, _headCy, _headRx, _headRy);

/// The shaded side of the face, as a crescent: the head minus itself shifted
/// up-left. Filled with a slightly darker skin tone, so a flat ellipse reads as
/// a form with a light on it.
///
/// Deliberately a small offset and a small step in value. A wider, darker
/// crescent turns the face into two flat halves with a seam down the middle,
/// which at picker size looks like a rendering fault rather than like light.
const _S _faceShade = _Sub(
  _head,
  _Ellipse(-0.068, _headCy - 0.038, _headRx, _headRy),
);

const _S _earLeft = _Ellipse(-0.352, 0.03, 0.062, 0.085);
const _S _earRight = _Ellipse(0.352, 0.03, 0.062, 0.085);

const _S _neck = _RRect(0, 0.44, 0.145, 0.16, 0.07);

/// Shoulders, sized so the crop is filled rather than fitted.
///
/// The ellipse's top is a point at y = 0.56, and by y = 0.8 it is already wider
/// than the circular crop — which is what stops a portrait sitting on a visible
/// shelf of background at the bottom of its own frame.
const double _shoulderCy = 1.26;
const double _shoulderRx = 1.02;
const double _shoulderRy = 0.70;
const _S _shoulders = _Ellipse(0, _shoulderCy, _shoulderRx, _shoulderRy);

/// The lit top edge of the garment — the shoulders minus a slightly smaller,
/// slightly lower copy of themselves.
const _S _collar = _Sub(
  _shoulders,
  _Ellipse(0, _shoulderCy + 0.045, _shoulderRx - 0.038, _shoulderRy - 0.045),
);

/// The default hair volume: an ellipse a little larger and higher than the
/// head, with the face cut out of it. Individual styles clip it, extend it or
/// replace it.
const _S _hairOuter = _Ellipse(0, -0.085, 0.404, 0.470);
const _S _faceCut = _Ellipse(0, 0.060, 0.343, 0.398);
const _S _hairBand = _Sub(_hairOuter, _faceCut);

/// The default outline the rim light traces.
const _S _defaultSilhouette = _Or(_head, _hairOuter);

/// The rim light itself: a silhouette minus the same silhouette shifted
/// down-right, leaving a crescent along its top-left edge.
_S _rimOf(_S silhouette) => _Sub(silhouette, _Shift(silhouette, 0.085, 0.048));

// ---------------------------------------------------------------------------
// Palettes
// ---------------------------------------------------------------------------

const _ink = _Rgb(0x11, 0x10, 0x18);

const _skinPorcelain = _Rgb(0xF2, 0xCD, 0xB2);
const _skinWarm = _Rgb(0xE8, 0xB2, 0x8C);
const _skinOlive = _Rgb(0xCE, 0x95, 0x6A);
const _skinTan = _Rgb(0xB2, 0x74, 0x4C);
const _skinBrown = _Rgb(0x8C, 0x57, 0x38);
const _skinDeep = _Rgb(0x60, 0x3B, 0x28);

const _hairNoir = _Rgb(0x16, 0x15, 0x1E);
const _hairEspresso = _Rgb(0x34, 0x23, 0x19);
const _hairChestnut = _Rgb(0x5C, 0x39, 0x23);
const _hairAsh = _Rgb(0x6D, 0x6D, 0x79);
const _hairPlatinum = _Rgb(0xDE, 0xDC, 0xE6);

const _garmentInk = _Rgb(0x17, 0x17, 0x1F);
const _garmentSlate = _Rgb(0x21, 0x22, 0x2C);
const _garmentCharcoal = _Rgb(0x2A, 0x2A, 0x33);

const _cyan = _Rgb(0x4F, 0xE3, 0xE0);
const _violet = _Rgb(0x9A, 0x6B, 0xFF);
const _magenta = _Rgb(0xFF, 0x5F, 0xB2);
const _lime = _Rgb(0xA9, 0xE2, 0x4C);
const _amber = _Rgb(0xFF, 0xB4, 0x3D);
const _iceBlue = _Rgb(0x74, 0xAC, 0xFF);
const _rose = _Rgb(0xFF, 0x7E, 0x7E);
const _teal = _Rgb(0x35, 0xCF, 0xA0);
const _azure = _Rgb(0x4D, 0x8C, 0xFF);
const _gold = _Rgb(0xF5, 0xC4, 0x51);
const _orange = _Rgb(0xFF, 0x8A, 0x3D);
const _coral = _Rgb(0xFF, 0x6B, 0x57);
const _silver = _Rgb(0xBD, 0xC9, 0xD8);
const _crimson = _Rgb(0xFF, 0x4D, 0x5E);
const _purple = _Rgb(0xB5, 0x58, 0xFF);
const _spring = _Rgb(0x5B, 0xE5, 0x8B);

/// One portrait's colours.
class _Face {
  const _Face({
    required this.skin,
    required this.hair,
    required this.garment,
    required this.accent,
  });

  final _Rgb skin;
  final _Rgb hair;
  final _Rgb garment;

  /// The one saturated colour in the picture. It lights the rim of the figure,
  /// tints the ground, and appears on exactly one worn object.
  final _Rgb accent;

  _Rgb get skinShade => _shade(skin, 0.91);
  _Rgb get neckShade => _shade(skin, 0.78);

  /// The mouth. A skin tone taken well down rather than a grey, because a grey
  /// bar on a warm face reads as an object stuck to it.
  _Rgb get mouth => _shade(skin, 0.50);
}

// ---------------------------------------------------------------------------
// The catalogue's artwork
// ---------------------------------------------------------------------------

/// One rendered portrait: its palette and its layers, back to front.
class _Design {
  const _Design(this.face, this.layers);
  final _Face face;
  final List<_Layer> layers;
}

/// A shape and the colour painted through it.
///
/// [alpha] is what makes the rim light and the visor glass work: a layer at
/// less than full opacity is composited over whatever is already there rather
/// than replacing it, so one primitive covers both "paint this" and "tint
/// this".
class _Layer {
  const _Layer(this.shape, this.colour, [this.alpha = 1.0]);
  final _S shape;
  final _Rgb colour;
  final double alpha;
}

/// The sixteen, in catalogue order.
///
/// Ordered so that neighbours in the picker's three-across grid differ in the
/// things the eye sorts by first: accent hue, hair silhouette, and what is
/// being worn. Two portraits that differ only in skin tone never sit side by
/// side, because at tile size that reads as a duplicate.
const List<_Design Function()> _designs = <_Design Function()>[
  _nova,
  _kairo,
  _vela,
  _rune,
  _iris,
  _onyx,
  _lyra,
  _atlas,
  _echo,
  _sable,
  _zephyr,
  _juno,
  _orbit,
  _ember,
  _nyx,
  _vox,
];

/// 01 Nova — the default avatar, so it is the one that has to carry the set:
/// straightforward crop, over-ear headphones, AURIX's own cyan.
_Design _nova() {
  const face = _Face(
    skin: _skinWarm,
    hair: _hairNoir,
    garment: _garmentInk,
    accent: _cyan,
  );
  final hair = _hairShort(face);
  return _assemble(face, hair: hair, worn: _headphones(face));
}

/// 02 Kairo — cyberpunk: shaved sides under a top knot, and a lit visor across
/// the eyes.
_Design _kairo() {
  const face = _Face(
    skin: _skinOlive,
    hair: _hairNoir,
    garment: _garmentSlate,
    accent: _violet,
  );
  final hair = _hairTopKnot(face);
  return _assemble(face, hair: hair, worn: _visor(face));
}

/// 03 Vela — long hair falling over the shoulders, headphones, hoop earrings.
_Design _vela() {
  const face = _Face(
    skin: _skinPorcelain,
    hair: _hairEspresso,
    garment: _garmentInk,
    accent: _magenta,
  );
  final hair = _hairLong(face);
  return _assemble(
    face,
    hair: hair,
    worn: <_Layer>[..._earrings(face), ..._headphones(face)],
  );
}

/// 04 Rune — a neon mohawk over a shaved head, and dark shades.
_Design _rune() {
  const face = _Face(
    skin: _skinTan,
    hair: _hairNoir,
    garment: _garmentCharcoal,
    accent: _lime,
  );
  final hair = _hairMohawk(face);
  return _assemble(face, hair: hair, worn: _shades(face));
}

/// 05 Iris — a blunt bob under a headband, with earrings.
_Design _iris() {
  const face = _Face(
    skin: _skinBrown,
    hair: _hairNoir,
    garment: _garmentSlate,
    accent: _amber,
  );
  final hair = _hairBob(face);
  return _assemble(
    face,
    hair: hair,
    worn: <_Layer>[..._headband(face), ..._earrings(face)],
  );
}

/// 06 Onyx — hood up. The one portrait where the garment, not the hair, makes
/// the silhouette.
_Design _onyx() {
  const face = _Face(
    skin: _skinDeep,
    hair: _hairNoir,
    garment: _garmentInk,
    accent: _iceBlue,
  );
  final hair = _hairBuzz(face);
  return _hooded(face, hair);
}

/// 07 Lyra — twin buns and headphones.
_Design _lyra() {
  const face = _Face(
    skin: _skinWarm,
    hair: _hairChestnut,
    garment: _garmentCharcoal,
    accent: _rose,
  );
  final hair = _hairTwinBuns(face);
  return _assemble(face, hair: hair, worn: _headphones(face));
}

/// 08 Atlas — beard and beanie.
_Design _atlas() {
  const face = _Face(
    skin: _skinTan,
    hair: _hairAsh,
    garment: _garmentSlate,
    accent: _teal,
  );
  final hair = _hairBeanie(face);
  return _assemble(face, hair: hair, beard: _beard(face));
}

/// 09 Echo — platinum undercut, headphones and a mic boom. The broadcast desk.
_Design _echo() {
  const face = _Face(
    skin: _skinPorcelain,
    hair: _hairPlatinum,
    garment: _garmentInk,
    accent: _azure,
  );
  final hair = _hairFade(face);
  return _assemble(
    face,
    hair: hair,
    worn: <_Layer>[..._headphones(face), ..._micBoom(face)],
  );
}

/// 10 Sable — a full curl silhouette, which is the one hairstyle in the set
/// that changes the outline the rim light traces.
_Design _sable() {
  const face = _Face(
    skin: _skinBrown,
    hair: _hairNoir,
    garment: _garmentInk,
    accent: _gold,
  );
  final hair = _hairCurls(face);
  return _assemble(face, hair: hair, worn: _earrings(face));
}

/// 11 Zephyr — a cap, worn forward.
_Design _zephyr() {
  const face = _Face(
    skin: _skinOlive,
    hair: _hairNoir,
    garment: _garmentCharcoal,
    accent: _orange,
  );
  final hair = _hairBuzz(face);
  return _assemble(face, hair: hair, worn: _cap(face));
}

/// 12 Juno — a wrapped headscarf, tied at the side.
_Design _juno() {
  const face = _Face(
    skin: _skinDeep,
    hair: _hairNoir,
    garment: _garmentInk,
    accent: _coral,
  );
  final hair = _hairWrap(face);
  return _assemble(face, hair: hair, worn: _earrings(face));
}

/// 13 Orbit — a helmet with a translucent visor, so the eyes read through the
/// glass rather than being covered by it.
///
/// The only portrait with no hair layer at all. A helmet that fits covers the
/// hair completely, and drawing it anyway left a near-black band showing
/// between the helmet's crown and its side wall — visible through the visor's
/// tint as a dark block beside the eyes.
_Design _orbit() {
  const face = _Face(
    skin: _skinPorcelain,
    hair: _hairNoir,
    garment: _garmentSlate,
    accent: _silver,
  );
  return _assemble(
    face,
    hair: const _Hair(silhouette: _Or(_head, _helmetShell)),
    worn: _helmet(face),
  );
}

/// 14 Ember — long waves under a headband.
_Design _ember() {
  const face = _Face(
    skin: _skinWarm,
    hair: _hairChestnut,
    garment: _garmentSlate,
    accent: _crimson,
  );
  final hair = _hairWaves(face);
  return _assemble(face, hair: hair, worn: _headband(face));
}

/// 15 Nyx — locs and shades.
_Design _nyx() {
  const face = _Face(
    skin: _skinOlive,
    hair: _hairNoir,
    garment: _garmentInk,
    accent: _purple,
  );
  final hair = _hairLocs(face);
  return _assemble(face, hair: hair, worn: _shades(face));
}

/// 16 Vox — a topknot bun, headphones and a mic boom.
_Design _vox() {
  const face = _Face(
    skin: _skinTan,
    hair: _hairEspresso,
    garment: _garmentCharcoal,
    accent: _spring,
  );
  final hair = _hairBun(face);
  return _assemble(
    face,
    hair: hair,
    worn: <_Layer>[..._headphones(face), ..._micBoom(face)],
  );
}

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

/// A hairstyle, in the three places it has to be drawn.
///
/// Hair is the one feature that lives on both sides of the figure: a bun sits
/// behind the head, a fringe sits in front of it, and long hair falls over the
/// shoulders it was drawn before. Splitting it here is what lets one assembly
/// order serve sixteen very different silhouettes.
class _Hair {
  const _Hair({
    this.behind = const <_Layer>[],
    this.front = const <_Layer>[],
    this.silhouette,
  });

  /// Drawn before the shoulders — hair mass that the body occludes.
  final List<_Layer> behind;

  /// Drawn after the head and before the face — everything that frames it.
  final List<_Layer> front;

  /// The outline the rim light follows, when the style changes it. Null means
  /// the default head-plus-hair ellipse.
  final _S? silhouette;
}

/// Stacks one portrait in the fixed order every avatar in the set uses.
///
/// The order is the whole family resemblance, so it lives in one function
/// rather than being restated sixteen times: body, then head, then hair, then
/// face, then the light, then the object being worn. Only [worn] is drawn after
/// the rim light, because a visor or a pair of headphones is in front of the
/// person and would look pasted on if the light fell across it.
_Design _assemble(
  _Face face, {
  required _Hair hair,
  List<_Layer> worn = const <_Layer>[],
  List<_Layer> beard = const <_Layer>[],
}) {
  return _Design(face, <_Layer>[
    ...hair.behind,
    _Layer(_shoulders, face.garment),
    _Layer(_collar, face.accent, 0.28),
    _Layer(_neck, face.neckShade),
    _Layer(_head, face.skin),
    _Layer(_faceShade, face.skinShade),
    _Layer(_earLeft, face.skin),
    _Layer(_earRight, face.skin),
    ...hair.front,
    ...beard,
    ..._features(face),
    _Layer(_rimOf(hair.silhouette ?? _defaultSilhouette), face.accent, 0.42),
    ...worn,
  ]);
}

/// Onyx's hood replaces the garment as the outermost shape, so it needs its own
/// order rather than a flag in [_assemble].
_Design _hooded(_Face face, _Hair hair) {
  final hood = _shade(face.garment, 1.5);
  const opening = _Ellipse(0, -0.02, 0.585, 0.615);
  const inner = _Ellipse(0, 0.045, 0.405, 0.470);

  return _Design(face, <_Layer>[
    _Layer(opening, hood),
    _Layer(_shoulders, face.garment),
    _Layer(_collar, face.accent, 0.28),
    _Layer(_neck, face.neckShade),
    _Layer(_head, face.skin),
    _Layer(_faceShade, face.skinShade),
    _Layer(_earLeft, face.skin),
    _Layer(_earRight, face.skin),
    ...hair.front,
    ..._features(face),
    // The cowl: everything of the opening that is not the face, kept above the
    // jaw so it frames rather than swallows.
    _Layer(const _And(_Sub(opening, inner), _Upper(0.44)), hood),
    _Layer(_rimOf(opening), face.accent, 0.40),
    _Layer(
      const _Sub(inner, _Ellipse(0, 0.045, 0.372, 0.437)),
      face.accent,
      0.34,
    ),
  ]);
}

/// Brows, eyes and mouth. Deliberately the same on every portrait.
///
/// Sixteen faces that also differ in expression would be sixteen *moods*, and a
/// profile picture picked once and seen for months is the wrong place for one.
/// The set varies by person, not by feeling.
List<_Layer> _features(_Face face) => <_Layer>[
      const _Layer(_RRect(-0.152, -0.148, 0.086, 0.019, 0.019), _ink),
      const _Layer(_RRect(0.152, -0.148, 0.086, 0.019, 0.019), _ink),
      const _Layer(_Ellipse(-0.148, -0.005, 0.052, 0.063), _ink),
      const _Layer(_Ellipse(0.148, -0.005, 0.052, 0.063), _ink),
      // A catchlight in each eye, in the accent rather than in white: it is two
      // pixels at picker size and it is what stops the eyes reading as holes.
      _Layer(const _Ellipse(-0.132, -0.026, 0.019, 0.021), face.accent, 0.85),
      _Layer(const _Ellipse(0.164, -0.026, 0.019, 0.021), face.accent, 0.85),
      _Layer(const _RRect(0, 0.216, 0.062, 0.020, 0.020), face.mouth),
    ];

// ---------------------------------------------------------------------------
// Hair
// ---------------------------------------------------------------------------

/// Cropped close, sitting on the scalp.
_Hair _hairShort(_Face face) => _Hair(
      front: <_Layer>[_Layer(const _And(_hairBand, _Upper(0.06)), face.hair)],
    );

/// Shorter still, and taken back off the temples.
_Hair _hairBuzz(_Face face) => _Hair(
      front: <_Layer>[
        _Layer(
          const _And(
            _Sub(
              _Ellipse(0, -0.055, 0.380, 0.452),
              _Ellipse(0, 0.075, 0.348, 0.400),
            ),
            _Upper(-0.02),
          ),
          face.hair,
        ),
      ],
    );

/// Falls past the shoulders. The side panels are drawn after the body on
/// purpose — hair this long is in front of what the figure is wearing.
_Hair _hairLong(_Face face) => _Hair(
      behind: <_Layer>[
        _Layer(const _Ellipse(0, -0.045, 0.455, 0.520), face.hair),
      ],
      front: <_Layer>[
        _Layer(const _And(_hairBand, _Upper(0.10)), face.hair),
        _Layer(const _RRect(-0.340, 0.300, 0.108, 0.400, 0.105), face.hair),
        _Layer(const _RRect(0.340, 0.300, 0.108, 0.400, 0.105), face.hair),
      ],
      silhouette: const _Or(_head, _Ellipse(0, -0.045, 0.455, 0.520)),
    );

/// Long, with the ends broken up so it does not read as two rectangles.
_Hair _hairWaves(_Face face) => _Hair(
      behind: <_Layer>[
        _Layer(const _Ellipse(0, -0.030, 0.470, 0.530), face.hair),
      ],
      front: <_Layer>[
        _Layer(const _And(_hairBand, _Upper(0.12)), face.hair),
        _Layer(const _RRect(-0.352, 0.260, 0.115, 0.360, 0.110), face.hair),
        _Layer(const _RRect(0.352, 0.260, 0.115, 0.360, 0.110), face.hair),
        _Layer(const _Ellipse(-0.395, 0.560, 0.098, 0.110), face.hair),
        _Layer(const _Ellipse(0.395, 0.560, 0.098, 0.110), face.hair),
        _Layer(const _Ellipse(-0.300, 0.630, 0.090, 0.095), face.hair),
        _Layer(const _Ellipse(0.300, 0.630, 0.090, 0.095), face.hair),
      ],
      silhouette: const _Or(_head, _Ellipse(0, -0.030, 0.470, 0.530)),
    );

/// A blunt bob: the band plus two straight slabs with a hard bottom edge.
_Hair _hairBob(_Face face) => _Hair(
      behind: <_Layer>[
        _Layer(const _Ellipse(0, -0.060, 0.435, 0.480), face.hair),
      ],
      front: <_Layer>[
        _Layer(const _And(_hairBand, _Upper(0.05)), face.hair),
        _Layer(const _RRect(-0.338, 0.150, 0.104, 0.300, 0.060), face.hair),
        _Layer(const _RRect(0.338, 0.150, 0.104, 0.300, 0.060), face.hair),
      ],
      silhouette: const _Or(_head, _Ellipse(0, -0.060, 0.435, 0.480)),
    );

/// Gathered into a bun above the crown.
_Hair _hairBun(_Face face) => _Hair(
      behind: <_Layer>[
        _Layer(const _Ellipse(0, -0.575, 0.150, 0.140), face.hair),
      ],
      front: <_Layer>[
        _Layer(const _And(_hairBand, _Upper(0.02)), face.hair),
        _Layer(const _RRect(0, -0.470, 0.088, 0.036, 0.030), _shade(face.hair, 1.6)),
      ],
      silhouette: const _Or(
        _Or(_head, _hairOuter),
        _Ellipse(0, -0.575, 0.150, 0.140),
      ),
    );

/// Two buns, set wide.
_Hair _hairTwinBuns(_Face face) => _Hair(
      behind: <_Layer>[
        _Layer(const _Ellipse(-0.318, -0.430, 0.132, 0.128), face.hair),
        _Layer(const _Ellipse(0.318, -0.430, 0.132, 0.128), face.hair),
      ],
      front: <_Layer>[_Layer(const _And(_hairBand, _Upper(0.04)), face.hair)],
      silhouette: const _Or(
        _Or(_head, _hairOuter),
        _Or(
          _Ellipse(-0.318, -0.430, 0.132, 0.128),
          _Ellipse(0.318, -0.430, 0.132, 0.128),
        ),
      ),
    );

/// Shaved sides with a crest running front to back, in the accent rather than
/// in a hair colour — the one place in the set where the neon is the hair.
_Hair _hairMohawk(_Face face) {
  const crest = _Fill(<_P>[
    _P(-0.118, -0.340),
    _P(-0.168, -0.520),
    _P(-0.108, -0.700),
    _P(0.020, -0.775),
    _P(0.145, -0.690),
    _P(0.178, -0.505),
    _P(0.118, -0.340),
  ]);

  return _Hair(
    behind: <_Layer>[_Layer(crest, face.accent)],
    front: <_Layer>[
      _Layer(
        const _And(
          _Sub(
            _Ellipse(0, -0.050, 0.378, 0.450),
            _Ellipse(0, 0.080, 0.350, 0.400),
          ),
          _Upper(-0.04),
        ),
        _shade(face.hair, 2.1),
      ),
      _Layer(const _And(crest, _Lower(-0.480)), face.accent),
    ],
    silhouette: const _Or(_Or(_head, _hairOuter), crest),
  );
}

/// A full curl silhouette. Scalloped with a ring of discs rather than left as a
/// smooth ellipse, because a smooth one reads as a helmet.
_Hair _hairCurls(_Face face) {
  const volume = _Or(
    _Ellipse(0, -0.105, 0.490, 0.505),
    _Or(
      _Ellipse(-0.360, -0.290, 0.150, 0.145),
      _Or(
        _Ellipse(0.360, -0.290, 0.150, 0.145),
        _Or(
          _Ellipse(-0.200, -0.470, 0.155, 0.150),
          _Or(
            _Ellipse(0.200, -0.470, 0.155, 0.150),
            _Ellipse(0, -0.545, 0.160, 0.150),
          ),
        ),
      ),
    ),
  );

  return _Hair(
    behind: <_Layer>[_Layer(volume, face.hair)],
    front: <_Layer>[
      _Layer(
        const _And(_Sub(volume, _Ellipse(0, 0.075, 0.340, 0.392)), _Upper(0.16)),
        face.hair,
      ),
    ],
    silhouette: const _Or(_head, volume),
  );
}

/// Long on one side, shaved on the other.
_Hair _hairFade(_Face face) => _Hair(
      behind: <_Layer>[
        _Layer(const _Ellipse(0.075, -0.060, 0.420, 0.490), face.hair),
      ],
      front: <_Layer>[
        // The shaved side, kept a shade back so the two halves separate.
        _Layer(
          const _And(_And(_hairBand, _Upper(-0.05)), _LeftOf(-0.02)),
          _shade(face.hair, 0.62),
        ),
        _Layer(const _And(_And(_hairBand, _Upper(0.10)), _RightOf(-0.02)), face.hair),
        _Layer(const _RRect(0.345, 0.235, 0.108, 0.335, 0.100), face.hair),
      ],
      silhouette: const _Or(_head, _Ellipse(0.075, -0.060, 0.420, 0.490)),
    );

/// Shaved sides under a knot on the crown.
_Hair _hairTopKnot(_Face face) => _Hair(
      behind: <_Layer>[
        _Layer(const _Ellipse(0, -0.545, 0.165, 0.118), face.hair),
      ],
      front: <_Layer>[
        _Layer(
          const _And(
            _Sub(
              _Ellipse(0, -0.060, 0.382, 0.455),
              _Ellipse(0, 0.075, 0.350, 0.400),
            ),
            _Upper(-0.10),
          ),
          _shade(face.hair, 1.9),
        ),
        _Layer(const _And(_hairBand, _Upper(-0.32)), face.hair),
      ],
      silhouette: const _Or(
        _Or(_head, _hairOuter),
        _Ellipse(0, -0.545, 0.165, 0.118),
      ),
    );

/// Locs, drawn as a row of capsules of unequal length.
_Hair _hairLocs(_Face face) {
  const xs = <double>[-0.300, -0.180, -0.060, 0.060, 0.180, 0.300];
  const lengths = <double>[0.300, 0.360, 0.330, 0.375, 0.340, 0.295];

  return _Hair(
    behind: <_Layer>[
      _Layer(const _Ellipse(0, -0.075, 0.425, 0.478), face.hair),
      for (var i = 0; i < xs.length; i++)
        _Layer(
          _RRect(xs[i] * 1.16, 0.170 + lengths[i], 0.052, lengths[i], 0.052),
          face.hair,
        ),
    ],
    front: <_Layer>[
      _Layer(const _And(_hairBand, _Upper(-0.04)), face.hair),
      for (var i = 0; i < xs.length; i++)
        _Layer(
          _RRect(xs[i], -0.360 - (i.isEven ? 0.02 : 0), 0.048, 0.075, 0.045),
          _shade(face.hair, 1.5),
        ),
    ],
    silhouette: const _Or(_head, _Ellipse(0, -0.075, 0.425, 0.478)),
  );
}

/// A beanie, pulled down to the brow with a folded band.
_Hair _hairBeanie(_Face face) {
  final knit = _shade(face.garment, 2.2);
  const crown = _And(_Ellipse(0, -0.125, 0.412, 0.470), _Upper(-0.115));

  return _Hair(
    front: <_Layer>[
      _Layer(const _And(_hairBand, _Upper(0.10)), face.hair),
      _Layer(crown, knit),
      _Layer(const _RRect(0, -0.150, 0.410, 0.078, 0.038), _shade(knit, 1.35)),
      _Layer(const _RRect(0, -0.196, 0.410, 0.014, 0.014), face.accent, 0.75),
    ],
    silhouette: const _Or(_head, _Ellipse(0, -0.125, 0.412, 0.470)),
  );
}

/// A wrapped headscarf, knotted at the side. Covers the hair entirely, which is
/// why the wrap colour rather than [_Face.hair] makes the silhouette.
_Hair _hairWrap(_Face face) {
  // Mixed well past halfway towards the accent on purpose. At a third, the
  // cloth landed within a few values of the skin tone underneath it and the
  // whole portrait flattened into one brown shape.
  final cloth = _mix(face.garment, face.accent, 0.62);
  const volume = _Ellipse(0, -0.095, 0.425, 0.490);

  return _Hair(
    behind: <_Layer>[_Layer(volume, cloth)],
    front: <_Layer>[
      _Layer(
        const _And(_Sub(volume, _Ellipse(0, 0.070, 0.340, 0.395)), _Upper(0.22)),
        cloth,
      ),
      // The fold across the brow, and the knot it ties into.
      _Layer(const _RRect(0, -0.310, 0.375, 0.052, 0.026), _shade(cloth, 1.3)),
      _Layer(const _Ellipse(0.352, -0.395, 0.108, 0.098), _shade(cloth, 1.3)),
      _Layer(const _Ellipse(0.452, -0.300, 0.070, 0.062), cloth),
    ],
    silhouette: const _Or(_head, volume),
  );
}

/// A close-cropped beard along the jaw, plus a moustache.
List<_Layer> _beard(_Face face) => <_Layer>[
      _Layer(
        const _And(
          _Sub(
            _Ellipse(0, 0.075, 0.372, 0.448),
            _Ellipse(0, -0.070, 0.300, 0.360),
          ),
          _Lower(0.010),
        ),
        face.hair,
      ),
      _Layer(const _RRect(0, 0.160, 0.098, 0.026, 0.024), face.hair),
    ];

// ---------------------------------------------------------------------------
// What the figure is wearing
// ---------------------------------------------------------------------------

/// Over-ear headphones: a band arcing over the hair, two cups, two cushions and
/// a lit ring on each cup.
List<_Layer> _headphones(_Face face) {
  final shell = _shade(face.garment, 1.25);
  final band = <_P>[
    for (var i = 0; i <= 40; i++)
      _P(
        0.487 * math.cos(math.pi + (math.pi * i / 40)),
        0.050 + (0.600 * math.sin(math.pi + (math.pi * i / 40))),
      ),
  ];

  return <_Layer>[
    _Layer(_Stroke(band, 0.038), shell),
    _Layer(_Stroke(_scaled(band, 0.90, 0.050), 0.011), face.accent, 0.70),
    for (final side in const <double>[-1, 1]) ...<_Layer>[
      _Layer(_RRect(side * 0.478, 0.045, 0.090, 0.148, 0.078), shell),
      _Layer(
        _RRect(side * 0.470, 0.045, 0.058, 0.112, 0.055),
        _mix(shell, _ink, 0.55),
      ),
      _Layer(
        _Sub(
          _Ellipse(side * 0.470, 0.045, 0.046, 0.046),
          _Ellipse(side * 0.470, 0.045, 0.028, 0.028),
        ),
        face.accent,
      ),
    ],
  ];
}

/// A lit visor across the eyes. Opaque — this one is a mask, not glass.
List<_Layer> _visor(_Face face) => <_Layer>[
      _Layer(const _RRect(-0.362, -0.020, 0.078, 0.034, 0.022), _shade(_ink, 2.0)),
      _Layer(const _RRect(0.362, -0.020, 0.078, 0.034, 0.022), _shade(_ink, 2.0)),
      // Deep enough to take in the brows. Sized to the eye line alone, the
      // brows sat a few pixels proud of the top edge and read as two tufts
      // pasted onto the visor.
      _Layer(const _RRect(0, -0.038, 0.398, 0.126, 0.058), _mix(_ink, _cyan, 0.06)),
      _Layer(const _RRect(0, -0.062, 0.344, 0.019, 0.014), face.accent),
      _Layer(const _RRect(0, -0.008, 0.290, 0.011, 0.009), face.accent, 0.45),
    ];

/// Dark shades, with one glint so the lenses are not two black holes.
List<_Layer> _shades(_Face face) => <_Layer>[
      _Layer(const _RRect(-0.330, -0.022, 0.062, 0.024, 0.014), _shade(_ink, 2.0)),
      _Layer(const _RRect(0.330, -0.022, 0.062, 0.024, 0.014), _shade(_ink, 2.0)),
      _Layer(const _RRect(0, -0.036, 0.052, 0.017, 0.010), _shade(_ink, 2.0)),
      const _Layer(_RRect(-0.158, -0.012, 0.128, 0.090, 0.048), _ink),
      const _Layer(_RRect(0.158, -0.012, 0.128, 0.090, 0.048), _ink),
      _Layer(const _RRect(-0.196, -0.042, 0.048, 0.013, 0.010), face.accent, 0.80),
      _Layer(const _RRect(0.120, -0.042, 0.048, 0.013, 0.010), face.accent, 0.35),
    ];

/// A cap with a peak, and a stripe in the accent.
List<_Layer> _cap(_Face face) {
  final cloth = _shade(face.garment, 2.0);
  return <_Layer>[
    _Layer(const _And(_Ellipse(0, -0.110, 0.408, 0.450), _Upper(-0.150)), cloth),
    // The peak, as it appears head-on: a shallow arc across the brow. Wider or
    // deeper than this and it stops being a cap and becomes a sun hat.
    _Layer(
      const _And(_Ellipse(0, -0.172, 0.442, 0.086), _Lower(-0.172)),
      _shade(cloth, 0.72),
    ),
    _Layer(const _RRect(0, -0.196, 0.402, 0.030, 0.014), face.accent),
    _Layer(const _Ellipse(0, -0.545, 0.036, 0.032), _shade(cloth, 0.72)),
  ];
}

/// The helmet's outer shell, named because the rim light traces it.
const _S _helmetShell = _Ellipse(0, -0.055, 0.472, 0.520);

/// A helmet with translucent glass, so the eyes drawn underneath read through
/// it. The alpha is the whole trick — an opaque visor here would delete the
/// face and leave a mannequin.
List<_Layer> _helmet(_Face face) {
  final shell = _shade(face.garment, 2.4);
  const outer = _helmetShell;

  return <_Layer>[
    _Layer(const _And(outer, _Upper(-0.180)), shell),
    _Layer(const _Sub(outer, _Ellipse(0, -0.030, 0.392, 0.452)), shell),
    _Layer(const _RRect(0, -0.030, 0.348, 0.140, 0.070), face.accent, 0.30),
    _Layer(
      const _Sub(
        _RRect(0, -0.030, 0.348, 0.140, 0.070),
        _RRect(0, -0.030, 0.330, 0.122, 0.062),
      ),
      face.accent,
      0.85,
    ),
    const _Layer(_RRect(-0.150, -0.080, 0.088, 0.012, 0.010), _Rgb(255, 255, 255), 0.35),
    _Layer(const _RRect(0, 0.330, 0.300, 0.050, 0.026), shell),
  ];
}

/// A boom mic swinging in from the left cup.
List<_Layer> _micBoom(_Face face) => <_Layer>[
      _Layer(
        const _Stroke(<_P>[
          _P(-0.470, 0.120),
          _P(-0.430, 0.240),
          _P(-0.330, 0.310),
          _P(-0.205, 0.322),
        ], 0.020),
        // Bright enough to read against the ground. At the shell's own value
        // the arm disappeared and left the mic floating by the chin.
        _shade(face.garment, 3.4),
      ),
      _Layer(const _Ellipse(-0.185, 0.322, 0.050, 0.048), face.accent),
    ];

/// Hoop earrings.
List<_Layer> _earrings(_Face face) => <_Layer>[
      for (final side in const <double>[-1, 1])
        _Layer(
          _Sub(
            _Ellipse(side * 0.352, 0.190, 0.054, 0.054),
            _Ellipse(side * 0.352, 0.190, 0.030, 0.030),
          ),
          face.accent,
        ),
    ];

/// A band across the forehead, clipped to the hair so its ends do not overshoot
/// the head.
List<_Layer> _headband(_Face face) => <_Layer>[
      _Layer(
        const _And(_RRect(0, -0.258, 0.400, 0.048, 0.024), _hairOuter),
        face.accent,
      ),
      _Layer(
        const _And(_RRect(0, -0.258, 0.400, 0.011, 0.008), _hairOuter),
        _shade(_ink, 1.4),
        0.35,
      ),
    ];

// ---------------------------------------------------------------------------
// Shape primitives
// ---------------------------------------------------------------------------
//
// Every shape answers one question — "is this point inside me?" — and reports a
// bounding box so the rasteriser can skip it for most of the tile. That pair is
// the entire geometry engine: no paths, no scanline fill, no clipper. It is
// enough because a portrait built this way is a stack of solids, and a stack of
// solids is exactly what point-in-shape plus painter's order gives you.

/// A point in portrait units.
class _P {
  const _P(this.x, this.y);
  final double x;
  final double y;
}

/// An axis-aligned bound, in portrait units.
class _Box {
  const _Box(this.x0, this.y0, this.x1, this.y1);

  final double x0;
  final double y0;
  final double x1;
  final double y1;

  bool overlaps(double ax0, double ay0, double ax1, double ay1) =>
      x0 <= ax1 && x1 >= ax0 && y0 <= ay1 && y1 >= ay0;

  _Box union(_Box other) => _Box(
        math.min(x0, other.x0),
        math.min(y0, other.y0),
        math.max(x1, other.x1),
        math.max(y1, other.y1),
      );

  _Box intersect(_Box other) => _Box(
        math.max(x0, other.x0),
        math.max(y0, other.y0),
        math.min(x1, other.x1),
        math.min(y1, other.y1),
      );
}

abstract class _S {
  const _S();
  bool at(double x, double y);
  _Box get bounds;
}

class _Ellipse extends _S {
  const _Ellipse(this.cx, this.cy, this.rx, this.ry);

  final double cx;
  final double cy;
  final double rx;
  final double ry;

  @override
  bool at(double x, double y) {
    final dx = (x - cx) / rx;
    final dy = (y - cy) / ry;
    return (dx * dx) + (dy * dy) <= 1;
  }

  @override
  _Box get bounds => _Box(cx - rx, cy - ry, cx + rx, cy + ry);
}

/// A rounded rectangle, which doubles as a capsule when the radius reaches half
/// the short side — which is how every bar, band and cushion in the set is
/// drawn.
class _RRect extends _S {
  const _RRect(this.cx, this.cy, this.hw, this.hh, this.r);

  final double cx;
  final double cy;
  final double hw;
  final double hh;
  final double r;

  @override
  bool at(double x, double y) {
    final radius = math.min(r, math.min(hw, hh));
    final dx = (x - cx).abs() - (hw - radius);
    final dy = (y - cy).abs() - (hh - radius);
    if (dx <= 0 && dy <= 0) return true;
    final ox = dx > 0 ? dx : 0.0;
    final oy = dy > 0 ? dy : 0.0;
    return (ox * ox) + (oy * oy) <= radius * radius;
  }

  @override
  _Box get bounds => _Box(cx - hw, cy - hh, cx + hw, cy + hh);
}

/// A stroked polyline with round caps and joins.
///
/// A stroked path is exactly the set of points within half the stroke width of
/// its centreline, so testing distance-to-segment gives round terminals and
/// mitre-free joins for free — no path machinery required.
class _Stroke extends _S {
  const _Stroke(this.points, this.width);

  final List<_P> points;
  final double width;

  @override
  bool at(double x, double y) {
    final half = width / 2;
    final rSq = half * half;
    for (var i = 0; i < points.length - 1; i++) {
      if (_distanceSqToSegment(x, y, points[i], points[i + 1]) <= rSq) {
        return true;
      }
    }
    return false;
  }

  @override
  _Box get bounds {
    var x0 = points.first.x, y0 = points.first.y;
    var x1 = x0, y1 = y0;
    for (final p in points) {
      x0 = math.min(x0, p.x);
      y0 = math.min(y0, p.y);
      x1 = math.max(x1, p.x);
      y1 = math.max(y1, p.y);
    }
    final half = width / 2;
    return _Box(x0 - half, y0 - half, x1 + half, y1 + half);
  }
}

/// A filled polygon, by even-odd crossing count.
class _Fill extends _S {
  const _Fill(this.points);

  final List<_P> points;

  @override
  bool at(double x, double y) {
    var inside = false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      final a = points[i];
      final b = points[j];
      if ((a.y > y) != (b.y > y) &&
          x < (((b.x - a.x) * (y - a.y)) / (b.y - a.y)) + a.x) {
        inside = !inside;
      }
    }
    return inside;
  }

  @override
  _Box get bounds {
    var x0 = points.first.x, y0 = points.first.y;
    var x1 = x0, y1 = y0;
    for (final p in points) {
      x0 = math.min(x0, p.x);
      y0 = math.min(y0, p.y);
      x1 = math.max(x1, p.x);
      y1 = math.max(y1, p.y);
    }
    return _Box(x0, y0, x1, y1);
  }
}

class _Or extends _S {
  const _Or(this.a, this.b);
  final _S a;
  final _S b;

  @override
  bool at(double x, double y) => a.at(x, y) || b.at(x, y);

  @override
  _Box get bounds => a.bounds.union(b.bounds);
}

class _And extends _S {
  const _And(this.a, this.b);
  final _S a;
  final _S b;

  @override
  bool at(double x, double y) => a.at(x, y) && b.at(x, y);

  @override
  _Box get bounds => a.bounds.intersect(b.bounds);
}

class _Sub extends _S {
  const _Sub(this.a, this.b);
  final _S a;
  final _S b;

  @override
  bool at(double x, double y) => a.at(x, y) && !b.at(x, y);

  @override
  _Box get bounds => a.bounds;
}

/// The same shape, moved. The rim light is a shape minus a shifted copy of
/// itself, which is why this exists.
class _Shift extends _S {
  const _Shift(this.shape, this.dx, this.dy);
  final _S shape;
  final double dx;
  final double dy;

  @override
  bool at(double x, double y) => shape.at(x - dx, y - dy);

  @override
  _Box get bounds {
    final b = shape.bounds;
    return _Box(b.x0 + dx, b.y0 + dy, b.x1 + dx, b.y1 + dy);
  }
}

/// Everything at or above [y] on screen — y points down, so this is `y <= k`.
class _Upper extends _S {
  const _Upper(this.k);
  final double k;

  @override
  bool at(double x, double y) => y <= k;

  @override
  _Box get bounds => _Box(-2, -2, 2, k);
}

class _Lower extends _S {
  const _Lower(this.k);
  final double k;

  @override
  bool at(double x, double y) => y >= k;

  @override
  _Box get bounds => _Box(-2, k, 2, 2);
}

class _LeftOf extends _S {
  const _LeftOf(this.k);
  final double k;

  @override
  bool at(double x, double y) => x <= k;

  @override
  _Box get bounds => _Box(-2, -2, k, 2);
}

class _RightOf extends _S {
  const _RightOf(this.k);
  final double k;

  @override
  bool at(double x, double y) => x >= k;

  @override
  _Box get bounds => _Box(k, -2, 2, 2);
}

/// A polyline scaled about a centre — used to inset the headphone band's lit
/// line inside the band itself.
List<_P> _scaled(List<_P> points, double factor, double aboutY) => <_P>[
      for (final p in points)
        _P(p.x * factor, aboutY + ((p.y - aboutY) * factor)),
    ];

double _distanceSqToSegment(double x, double y, _P a, _P b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final lengthSq = (dx * dx) + (dy * dy);

  var t = 0.0;
  if (lengthSq > 0) {
    t = ((((x - a.x) * dx) + ((y - a.y) * dy)) / lengthSq).clamp(0.0, 1.0);
  }

  final ex = x - (a.x + (t * dx));
  final ey = y - (a.y + (t * dy));
  return (ex * ex) + (ey * ey);
}

// ---------------------------------------------------------------------------
// Rasteriser
// ---------------------------------------------------------------------------

Uint8List _render(_Design design, int size) {
  final pixels = Uint8List(size * size * 3);
  final layers = design.layers;
  final boxes = <_Box>[for (final layer in layers) layer.shape.bounds];

  final s = size.toDouble();

  /// Width of one pixel in portrait units.
  final du = 2.0 / s;

  /// Offset from a pixel's leading edge to the first sample centre.
  final sub = du / _ss;
  const weight = 1.0 / (_ss * _ss);

  final candidates = <int>[];

  for (var py = 0; py < size; py++) {
    final uy0 = (py * du) - 1;
    final uy1 = uy0 + du;

    // Rows that no layer reaches at all are pure background, and there are a
    // lot of them above a portrait's hair. Culling per row first means those
    // never enter the per-pixel loop's bounds test either.
    final rowLayers = <int>[
      for (var i = 0; i < layers.length; i++)
        if (boxes[i].overlaps(-2, uy0, 2, uy1)) i,
    ];

    for (var px = 0; px < size; px++) {
      final ux0 = (px * du) - 1;
      final ux1 = ux0 + du;

      candidates
        ..clear()
        ..addAll(<int>[
          for (final i in rowLayers)
            if (boxes[i].overlaps(ux0, uy0, ux1, uy1)) i,
        ]);

      _Rgb colour;
      if (candidates.isEmpty) {
        // Pure ground. It is a smooth function, so one sample at the pixel
        // centre is indistinguishable from sixteen and costs a sixteenth.
        colour = _ground(design.face, ux0 + (du / 2), uy0 + (du / 2));
      } else {
        var r = 0.0, g = 0.0, b = 0.0;
        for (var sy = 0; sy < _ss; sy++) {
          final uy = uy0 + ((sy + 0.5) * sub);
          for (var sx = 0; sx < _ss; sx++) {
            final ux = ux0 + ((sx + 0.5) * sub);
            var c = _ground(design.face, ux, uy);
            for (final i in candidates) {
              final layer = layers[i];
              if (!layer.shape.at(ux, uy)) continue;
              c = layer.alpha >= 1
                  ? layer.colour
                  : _lerp(c, layer.colour, layer.alpha);
            }
            r += c.r * weight;
            g += c.g * weight;
            b += c.b * weight;
          }
        }
        colour = _Rgb(r.round(), g.round(), b.round());
      }

      final i = ((py * size) + px) * 3;
      pixels[i] = colour.r;
      pixels[i + 1] = colour.g;
      pixels[i + 2] = colour.b;
    }
  }

  return _encodePng(size, size, pixels);
}

/// The background: a diagonal gradient in the avatar's own hue, a glow behind
/// the head, and a vignette at the rim.
///
/// The vignette is not decoration. It gives every avatar a defined edge inside
/// the circular crop the UI applies, in both themes, without drawing a border
/// on any of them — and it is what stops the accent glow washing out to the
/// tile's corners, where the crop would cut it mid-gradient.
_Rgb _ground(_Face face, double ux, double uy) {
  final diagonal = ((ux + uy + 2) / 4).clamp(0.0, 1.0);
  var colour = _lerp(
    _mix(const _Rgb(0x08, 0x08, 0x0C), face.accent, 0.20),
    _mix(const _Rgb(0x05, 0x05, 0x08), face.accent, 0.05),
    diagonal,
  );

  // The glow sits behind where the head will be, not at the tile's centre.
  final gx = ux / 0.95;
  final gy = (uy + 0.16) / 0.95;
  final glow = (1 - math.sqrt((gx * gx) + (gy * gy))).clamp(0.0, 1.0);
  colour = _lerp(colour, face.accent, 0.30 * glow * glow);

  final radius = math.sqrt((ux * ux) + (uy * uy));
  final t = ((radius - 0.54) / 0.62).clamp(0.0, 1.0);
  final falloff = t * t * (3 - (2 * t)); // smoothstep
  return _lerp(colour, _shade(colour, 0.38), falloff * 0.85);
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;
}

/// Multiplies a colour's brightness. Factors above 1 lighten, and the clamp is
/// what keeps `_shade(_ink, 2.6)` — the mouth — from wrapping around.
_Rgb _shade(_Rgb colour, double factor) => _Rgb(
      (colour.r * factor).round().clamp(0, 255),
      (colour.g * factor).round().clamp(0, 255),
      (colour.b * factor).round().clamp(0, 255),
    );

_Rgb _mix(_Rgb a, _Rgb b, double t) => _lerp(a, b, t);

_Rgb _lerp(_Rgb a, _Rgb b, double t) {
  final u = t.clamp(0.0, 1.0);
  return _Rgb(
    (a.r + ((b.r - a.r) * u)).round().clamp(0, 255),
    (a.g + ((b.g - a.g) * u)).round().clamp(0, 255),
    (a.b + ((b.b - a.b) * u)).round().clamp(0, 255),
  );
}

// ---------------------------------------------------------------------------
// PNG encoding
// ---------------------------------------------------------------------------

/// Minimal 8-bit RGB PNG writer: signature, IHDR, one IDAT, IEND.
///
/// Two deliberate differences from the launcher-icon writer, both of which pay
/// for themselves sixteen times over here:
///
///  * **No alpha channel.** An avatar is an opaque tile — the circular crop is
///    applied by the UI, not baked into the file — so the alpha byte would be
///    0xFF on every one of 102,400 pixels.
///  * **Adaptive filtering.** These images are large smooth areas broken by
///    hard shape edges, which is the case row filters exist for. Choosing per
///    scanline with the standard minimum-sum-of-absolute-differences heuristic
///    cuts the set to a fraction of what unfiltered scanlines produce.
Uint8List _encodePng(int width, int height, Uint8List rgb) {
  const bpp = 3;
  final stride = width * bpp;

  final raw = BytesBuilder();
  var prior = Uint8List(stride);
  final candidate = Uint8List(stride);
  final best = Uint8List(stride);

  for (var y = 0; y < height; y++) {
    final line = Uint8List.sublistView(rgb, y * stride, (y + 1) * stride);

    var bestFilter = 0;
    var bestScore = -1;

    for (var filter = 0; filter < 5; filter++) {
      var score = 0;
      for (var i = 0; i < stride; i++) {
        final left = i >= bpp ? line[i - bpp] : 0;
        final up = prior[i];
        final upLeft = i >= bpp ? prior[i - bpp] : 0;

        final predicted = switch (filter) {
          1 => left,
          2 => up,
          3 => (left + up) >> 1,
          4 => _paeth(left, up, upLeft),
          _ => 0,
        };

        final value = (line[i] - predicted) & 0xFF;
        candidate[i] = value;
        // Signed-byte magnitude: the heuristic favours values near zero, which
        // is what the deflate stage downstream actually compresses well.
        score += value < 128 ? value : 256 - value;
      }

      if (bestScore < 0 || score < bestScore) {
        bestScore = score;
        bestFilter = filter;
        best.setAll(0, candidate);
      }
    }

    raw
      ..addByte(bestFilter)
      ..add(best);
    prior = Uint8List.fromList(line);
  }

  final compressed = ZLibCodec(level: 9).encode(raw.toBytes());

  final ihdr = BytesBuilder()
    ..add(_uint32(width))
    ..add(_uint32(height))
    ..addByte(8) // bit depth
    ..addByte(2) // colour type: RGB
    ..addByte(0) // compression
    ..addByte(0) // filter
    ..addByte(0); // interlace

  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', ihdr.toBytes()))
    ..add(_chunk('IDAT', Uint8List.fromList(compressed)))
    ..add(_chunk('IEND', Uint8List(0)));

  return out.toBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

Uint8List _chunk(String type, Uint8List data) {
  final body = (BytesBuilder()
        ..add(Uint8List.fromList(type.codeUnits))
        ..add(data))
      .toBytes();

  return (BytesBuilder()
        ..add(_uint32(data.length))
        ..add(body)
        ..add(_uint32(_crc32(body))))
      .toBytes();
}

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Uint8List bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
