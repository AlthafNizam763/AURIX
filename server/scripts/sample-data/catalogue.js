/**
 * The AURIX demo catalogue: songs, artists, albums, genres and playlists.
 *
 * ## Why this file exists
 *
 * A music app with an empty database cannot be tested. Every screen degrades
 * to its empty state, search returns nothing, and the four player surfaces
 * have nothing to draw — so "does the mini player theme apply?" is not a
 * question anyone can answer. This is the fixture that makes the rest of the
 * app exercisable, and it is checked in rather than generated so that two
 * developers seeding on different days get the same catalogue.
 *
 * ## The licensing rule, and why it shapes the data
 *
 * Every recording below is **public domain, CC0, or Creative Commons
 * Attribution**, and every one is hosted by Wikimedia Commons. That is not a
 * stylistic preference — it is the same rule the importers obey, stated in
 * data instead of in code:
 *
 *   AURIX streams audio only where it is authorised to. It never rips,
 *   downloads, re-hosts or re-encodes audio it is not licensed for.
 *
 * A demo catalogue full of chart pop with `previewUrl` pointing at some
 * scraped CDN would contradict every safeguard in `AudioSourceResolver` and
 * `SpotifyPlaylistFetcher`, and would be the single most likely thing in the
 * repository to end up in production by accident. So the demo data is music
 * that is genuinely free to stream, and the `license` / `attribution` fields
 * below are carried per track so the claim is auditable rather than asserted
 * once in a comment.
 *
 * These are `source: 'aurix'` songs. They are not imported from anywhere, they
 * carry no `spotifyId` or `youtubeVideoId`, and they are the only rows in the
 * catalogue that AURIX itself may stream end to end — which makes them the
 * only rows that exercise the `licensedPreview` branch of the resolver with a
 * *full* track rather than a thirty-second clip.
 *
 * ## Audio URLs: why the transcode and not the original
 *
 * Commons stores most of these as Ogg Vorbis. Android plays Ogg; iOS does not.
 * Commons publishes an MP3 transcode of every audio file at a derived path,
 * and that is what `previewUrl` points at, so one catalogue works on both
 * platforms. Files already uploaded as MP3 are used directly — there is no
 * transcode of a transcode. See [mp3Url].
 *
 * ## Durations are measured, not guessed
 *
 * `durationMs` comes from the Commons `playtime_seconds` metadata of the
 * actual file, not from a lookup of the piece. A wrong duration is not
 * cosmetic here: the scrubber, the remaining-time label and the auto-advance
 * to the next track are all driven by it, so a guessed value produces a player
 * that visibly misbehaves.
 *
 * ## Keeping it honest
 *
 * `seed-samples.js` range-requests every audio and artwork URL before it
 * writes anything, and refuses to seed if one of them is not reachable audio.
 * `test/sample-data.test.js` checks the manifest's internal consistency —
 * unique ids, resolvable playlist references, genre coverage — without
 * touching the network. Between them, "the demo data has a broken link" is a
 * failure you get told about rather than one you discover in the player.
 */

/** Commons file paths are `<a>/<ab>/<name>`; the MP3 transcode hangs off that. */
function mp3Url(shard, name) {
  return name.toLowerCase().endsWith('.mp3')
    ? `https://upload.wikimedia.org/wikipedia/commons/${shard}/${name}`
    : `https://upload.wikimedia.org/wikipedia/commons/transcoded/${shard}/${name}/${name}.mp3`;
}

/** A Commons thumbnail, sized once for artwork rather than per surface. */
function art(path) {
  return `https://upload.wikimedia.org/wikipedia/commons/${path}`;
}

// ---------------------------------------------------------------------------
// Genres
// ---------------------------------------------------------------------------

/**
 * The genre vocabulary the demo songs are tagged with.
 *
 * These deliberately reuse ids from `MoodCatalogue` in the client where one
 * exists (`jazz`, `rock`), so a demo song tagged `jazz` is reachable from the
 * Search screen's existing genre tile rather than from a parallel taxonomy
 * that only the seed knows about. Ids that have no tile yet (`classical`,
 * `ragtime`, `band`) are still recorded on the song, because the tag is what a
 * future tile would filter on and dropping it would make adding one a data
 * migration.
 */
export const GENRES = [
  { id: 'classical', name: 'Classical' },
  { id: 'jazz', name: 'Jazz' },
  { id: 'ragtime', name: 'Ragtime' },
  { id: 'band', name: 'Concert Band' },
  { id: 'rock', name: 'Rock' },
];

// ---------------------------------------------------------------------------
// Albums
// ---------------------------------------------------------------------------

/**
 * The albums the demo songs belong to.
 *
 * AURIX has no `albums` collection — an album is a *field* on a song plus the
 * artwork that song carries, which is what `Song.asTrack` reconstructs an
 * `Album` from. So these are not written as documents; they are the single
 * place the album name and cover are spelled, and the songs below reference
 * them by key. That keeps every track of one album agreeing about its cover,
 * which is the property the Album screen and the player background rely on.
 */
export const ALBUMS = {
  musopenOrchestral: {
    name: 'Musopen Orchestral Sessions',
    artwork: art(
      'thumb/0/01/Vincent_van_Gogh_-_Starry_Night_-_Google_Art_Project.jpg/960px-Vincent_van_Gogh_-_Starry_Night_-_Google_Art_Project.jpg',
    ),
  },
  baroque: {
    name: 'Baroque Masters',
    artwork: art('thumb/6/6a/Johann_Sebastian_Bach.jpg/960px-Johann_Sebastian_Bach.jpg'),
  },
  pianoMiniatures: {
    name: 'Piano Miniatures',
    artwork: art(
      'thumb/3/36/Fr%C3%A9d%C3%A9ric_Chopin_by_Bisson%2C_1849.png/960px-Fr%C3%A9d%C3%A9ric_Chopin_by_Bisson%2C_1849.png',
    ),
  },
  hotJazz: {
    name: 'Hot Jazz 1914-1929',
    artwork: art('c/ca/Scott_Joplin_19072.jpg'),
  },
  airForce: {
    name: 'Air Force Band Sessions',
    artwork: art(
      'thumb/a/a4/Piet_Mondriaan%2C_1930_-_Mondrian_Composition_II_in_Red%2C_Blue%2C_and_Yellow.jpg/960px-Piet_Mondriaan%2C_1930_-_Mondrian_Composition_II_in_Red%2C_Blue%2C_and_Yellow.jpg',
    ),
  },
  openSignals: {
    name: 'Open Signals',
    artwork: art(
      '6/63/Robert_Delaunay%2C_1913%2C_Premier_Disque%2C_134_cm%2C_52.7_inches%2C_Private_collection.jpg',
    ),
  },
};

// ---------------------------------------------------------------------------
// Songs
// ---------------------------------------------------------------------------

/**
 * The demo songs.
 *
 * `id` is a stable, human-readable slug rather than a hash. It is the
 * catalogue document's `_id`, so it is what makes a re-seed an update of the
 * same twenty rows instead of twenty new ones — the same duplicate-avoidance
 * property the importers get from `SongKey`, obtained here by simply choosing
 * the key.
 *
 * `artists` is a list because the model's is: the credit on a 1927 dance-band
 * side is genuinely two names, and flattening it to a string would lose the
 * featured-artist search that `tokensForSong` provides.
 */
export const SONGS = [
  // ---- Classical / orchestral -------------------------------------------
  {
    id: 'aurix-demo-borodin-steppes',
    title: 'In the Steppes of Central Asia',
    artists: ['Musopen Symphony Orchestra'],
    album: ALBUMS.musopenOrchestral,
    genre: 'classical',
    durationMs: 458_240,
    previewUrl: mp3Url('b/be', 'Alexander_Borodin_-_In_The_Steppes_Of_Central_Asia.ogg'),
    license: 'CC0',
    attribution:
      'Alexander Borodin, performed by the Musopen Symphony Orchestra (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-dvorak-new-world-largo',
    title: "Symphony No. 9 'From the New World', Op. 95 - II. Largo",
    artists: ['Antonin Dvorak'],
    album: ALBUMS.musopenOrchestral,
    genre: 'classical',
    durationMs: 694_464,
    previewUrl: mp3Url(
      'c/c3',
      "Antonin_Dvorak_-_symphony_no._9_in_e_minor_%27from_the_new_world%27%2C_op._95_-_ii._largo.ogg",
    ),
    license: 'Public domain',
    attribution: 'Antonin Dvorak, Musopen recording (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-mendelssohn-wedding-march',
    title: "A Midsummer Night's Dream, Op. 61 - Wedding March",
    artists: ['European Archive'],
    album: ALBUMS.musopenOrchestral,
    genre: 'classical',
    durationMs: 293_640,
    previewUrl: mp3Url(
      'c/cb',
      "A_Midsummer_Night%27s_Dream_Op._61_Wedding_March_%28Mendelssohn%29_European_Archive.ogg",
    ),
    license: 'Public domain',
    attribution: 'Felix Mendelssohn, European Archive recording (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-glazunov-chant-du-menestrel',
    title: 'Chant du menestrel, Op. 71',
    artists: ['Alexander Glazunov'],
    album: ALBUMS.musopenOrchestral,
    genre: 'classical',
    durationMs: 232_032,
    previewUrl: mp3Url('5/54', 'Alexander_Glazunov_-_chant_du_menestrel%2C_op._71.ogg'),
    license: 'Public domain',
    attribution: 'Alexander Glazunov, Musopen recording (Wikimedia Commons)',
  },

  // ---- Baroque ----------------------------------------------------------
  {
    id: 'aurix-demo-bach-jesu-joy',
    title: 'Jesus bleibet meine Freude, BWV 147',
    artists: ['Orchestra Gli Armonici'],
    album: ALBUMS.baroque,
    genre: 'classical',
    durationMs: 202_266,
    previewUrl: mp3Url('2/27', 'Bach%2C_BWV_147%2C_10._Jesus_bleibet_meine_Freude.ogg'),
    license: 'CC0',
    attribution: 'J. S. Bach, performed by Orchestra Gli Armonici (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-bach-goldberg-aria',
    title: 'Goldberg Variations, BWV 988 - Aria',
    artists: ['Johann Sebastian Bach'],
    album: ALBUMS.baroque,
    genre: 'classical',
    durationMs: 287_056,
    previewUrl: mp3Url('a/af', 'Bach%2C_Goldberg_Variations%2C_Aria_%28Musopen_version%29.ogg'),
    license: 'CC0',
    attribution: 'J. S. Bach, Musopen recording (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-albinoni-oboe-adagio',
    title: 'Oboe Concerto No. 2 in D minor, Op. 9 - II. Adagio',
    artists: ['Tomaso Albinoni'],
    album: ALBUMS.baroque,
    genre: 'classical',
    durationMs: 257_750,
    previewUrl: mp3Url(
      'd/da',
      'Albinoni%2C_Concerto_for_Oboe_and_Strings_No._2_in_D_minor%2C_Op._9%2C_II._Adagio.ogg',
    ),
    license: 'CC0',
    attribution: 'Tomaso Albinoni, Musopen recording (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-vivaldi-mandolin-rv425',
    title: 'Mandolin Concerto in C major, RV 425',
    artists: ['The Milan Baroque Soloists'],
    album: ALBUMS.baroque,
    genre: 'classical',
    durationMs: 499_931,
    previewUrl: mp3Url('6/60', 'Antonio_Vivaldi%2C_Mandolin_Concerto_in_C_major%2C_RV_425.ogg'),
    license: 'Public Domain Mark',
    attribution: 'Antonio Vivaldi, performed by The Milan Baroque Soloists (Wikimedia Commons)',
  },

  // ---- Solo piano -------------------------------------------------------
  {
    id: 'aurix-demo-chopin-allegro-de-concert',
    title: 'Allegro de Concert, Op. 46 in A major',
    artists: ['Frederic Chopin'],
    album: ALBUMS.pianoMiniatures,
    genre: 'classical',
    durationMs: 760_038,
    previewUrl: mp3Url('a/a0', 'Allegro_de_Concert_Op._46_in_A_Major.mp3'),
    license: 'CC0',
    attribution: 'Frederic Chopin, Musopen recording (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-scriabin-prelude-op67',
    title: 'Prelude No. 1, Op. 67',
    artists: ['Alexander Scriabin'],
    album: ALBUMS.pianoMiniatures,
    genre: 'classical',
    durationMs: 117_290,
    previewUrl: mp3Url('e/e5', 'Alexander_Scriabin_-_prelude_no._1%2C_op._67.ogg'),
    license: 'Public domain',
    attribution: 'Alexander Scriabin, Musopen recording (Wikimedia Commons)',
  },

  // ---- Hot jazz and ragtime ---------------------------------------------
  {
    id: 'aurix-demo-schutt-bluin-black-keys',
    title: "Bluin' the Black Keys",
    artists: ['Arthur Schutt'],
    album: ALBUMS.hotJazz,
    genre: 'jazz',
    durationMs: 255_821,
    previewUrl: mp3Url('d/d8', '%22Bluin%27_the_Black_Keys%22_%281926%29%2C_by_Arthur_Schutt.oga'),
    license: 'Public domain',
    attribution: 'Arthur Schutt, 1926 recording (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-goldkette-clementine',
    title: 'Clementine',
    artists: ['Jean Goldkette & His Orchestra', 'Bix Beiderbecke'],
    album: ALBUMS.hotJazz,
    genre: 'jazz',
    durationMs: 179_601,
    previewUrl: mp3Url(
      'd/d9',
      '%22Clementine%22_%281927%29%2C_by_Jean_Goldkette_%26_His_Orchestra%2C_featuring_Bix_Beiderbecke.oga',
    ),
    license: 'Public domain',
    attribution: 'Jean Goldkette & His Orchestra ft. Bix Beiderbecke, 1927 (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-paques-crooked-notes',
    title: 'Crooked Notes',
    artists: ['Jean Paques'],
    album: ALBUMS.hotJazz,
    genre: 'jazz',
    durationMs: 157_981,
    previewUrl: mp3Url('3/37', '%22Crooked_Notes%22_%281929%29%2C_by_Jean_Paques.oga'),
    license: 'Public domain',
    attribution: 'Jean Paques, 1929 recording (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-frosini-new-york-blues',
    title: 'New York Blues',
    artists: ['Pietro Frosini'],
    album: ALBUMS.hotJazz,
    genre: 'jazz',
    durationMs: 199_622,
    previewUrl: mp3Url('a/ac', 'Pietro_Frosini_-_New_York_Blues_%281916%29_-_unrestored.ogg'),
    license: 'Public domain',
    attribution: 'Pietro Frosini, 1916 recording (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-nazareth-brejeiro',
    title: 'Brejeiro',
    artists: ['Ernesto Nazareth'],
    album: ALBUMS.hotJazz,
    genre: 'ragtime',
    durationMs: 123_621,
    previewUrl: mp3Url('3/34', '%22Brejeiro%22_%281914%29%2C_by_Ernesto_Nazareth.oga'),
    license: 'Public domain',
    attribution: 'Ernesto Nazareth, 1914 recording (Wikimedia Commons)',
  },

  // ---- Concert band -----------------------------------------------------
  {
    id: 'aurix-demo-usaf-america-the-beautiful',
    title: 'America the Beautiful',
    artists: ['United States Air Force Band of Mid-America'],
    album: ALBUMS.airForce,
    genre: 'band',
    durationMs: 262_068,
    previewUrl: mp3Url(
      '3/36',
      'America_the_Beautiful_-_Starlifter_-_United_States_Air_Force_Band_of_Mid-America.mp3',
    ),
    license: 'Public domain',
    attribution: 'US Air Force Band of Mid-America - a work of the US federal government',
  },
  {
    id: 'aurix-demo-usaf-america',
    title: 'America',
    artists: ['United States Air Force Heritage of America Band'],
    album: ALBUMS.airForce,
    genre: 'band',
    durationMs: 173_621,
    previewUrl: mp3Url(
      '4/4d',
      'America_-_Blue_Aces_-_United_States_Air_Force_Heritage_of_America_Band.mp3',
    ),
    license: 'Public domain',
    attribution: 'US Air Force Heritage of America Band - a work of the US federal government',
  },
  {
    id: 'aurix-demo-usaf-4th-street-exit',
    title: '4th Street Exit',
    artists: ['United States Air Force Band of Flight'],
    album: ALBUMS.airForce,
    genre: 'band',
    durationMs: 255_514,
    previewUrl: mp3Url(
      '7/78',
      '4th_Street_Exit_-_Systems_Go_-_United_States_Air_Force_Band_of_Flight.mp3',
    ),
    license: 'Public domain',
    attribution: 'US Air Force Band of Flight - a work of the US federal government',
  },

  // ---- Contemporary, Creative Commons ------------------------------------
  {
    id: 'aurix-demo-amouth-city-of-gold',
    title: 'City of Gold',
    artists: ['Amouth'],
    album: ALBUMS.openSignals,
    genre: 'rock',
    durationMs: 362_036,
    previewUrl: mp3Url('5/5f', 'Amouth_-_City_of_Gold.ogg'),
    license: 'CC BY 3.0',
    attribution: 'Amouth - City of Gold, licensed CC BY 3.0 (Wikimedia Commons)',
  },
  {
    id: 'aurix-demo-spelled-moon-war-of-shadows',
    title: 'A War of Shadows',
    artists: ['Spelled Moon'],
    album: ALBUMS.openSignals,
    genre: 'rock',
    durationMs: 35_785,
    previewUrl: mp3Url('f/f0', 'A_War_Of_Shadows_by_Spelled_Moon.ogg'),
    license: 'CC BY-SA 3.0',
    attribution: 'Spelled Moon - A War of Shadows, licensed CC BY-SA 3.0 (Wikimedia Commons)',
  },
];

// ---------------------------------------------------------------------------
// Playlists
// ---------------------------------------------------------------------------

/**
 * The demo playlists, written into `globalPlaylists` — the *shared* catalogue.
 *
 * Shared rather than per-user on purpose. A playlist seeded into one
 * developer's account would not answer the question the demo data exists to
 * answer, which is whether a playlist one person put into AURIX is findable
 * and playable by everyone else (the requirement `sharedPlaylists.routes.js`
 * implements). Seeding them globally means a fresh install with no account
 * history still has something in search and something to open.
 *
 * `source: 'aurix'` and a `sourceId` of the playlist's own slug. That pair is
 * the identity the importers dedupe on, so giving the demo playlists a real
 * one keeps them in the same namespace as imported playlists rather than in a
 * special case the import path has to know about.
 *
 * `songs` is an ordered list of song ids. Order is data, not incidental: the
 * seed writes `position` from the index, and `test/sample-data.test.js` checks
 * every id resolves — a typo here would otherwise produce a playlist that is
 * quietly one track short.
 */
export const PLAYLISTS = [
  {
    id: 'aurix-demo-playlist-orchestral-openers',
    name: 'Orchestral Openers',
    description:
      'Big public-domain orchestral writing, for testing long tracks and the full-screen player.',
    genre: 'classical',
    cover: ALBUMS.musopenOrchestral.artwork,
    songs: [
      'aurix-demo-borodin-steppes',
      'aurix-demo-mendelssohn-wedding-march',
      'aurix-demo-dvorak-new-world-largo',
      'aurix-demo-glazunov-chant-du-menestrel',
    ],
  },
  {
    id: 'aurix-demo-playlist-baroque-focus',
    name: 'Baroque Focus',
    description: 'Bach, Albinoni and Vivaldi. Quiet enough to work to.',
    genre: 'classical',
    cover: ALBUMS.baroque.artwork,
    songs: [
      'aurix-demo-bach-goldberg-aria',
      'aurix-demo-albinoni-oboe-adagio',
      'aurix-demo-bach-jesu-joy',
      'aurix-demo-vivaldi-mandolin-rv425',
    ],
  },
  {
    id: 'aurix-demo-playlist-hot-jazz',
    name: 'Hot Jazz and Ragtime',
    description: 'Dance-band sides and novelty piano from 1914 to 1929.',
    genre: 'jazz',
    cover: ALBUMS.hotJazz.artwork,
    songs: [
      'aurix-demo-goldkette-clementine',
      'aurix-demo-schutt-bluin-black-keys',
      'aurix-demo-nazareth-brejeiro',
      'aurix-demo-paques-crooked-notes',
      'aurix-demo-frosini-new-york-blues',
    ],
  },
  {
    id: 'aurix-demo-playlist-marching-band',
    name: 'Concert Band',
    description: 'United States Air Force bands, in the public domain.',
    genre: 'band',
    cover: ALBUMS.airForce.artwork,
    songs: [
      'aurix-demo-usaf-america-the-beautiful',
      'aurix-demo-usaf-4th-street-exit',
      'aurix-demo-usaf-america',
    ],
  },
  {
    id: 'aurix-demo-playlist-piano',
    name: 'Piano Miniatures',
    description: 'Chopin and Scriabin at the keyboard.',
    genre: 'classical',
    cover: ALBUMS.pianoMiniatures.artwork,
    songs: ['aurix-demo-scriabin-prelude-op67', 'aurix-demo-chopin-allegro-de-concert'],
  },
  {
    // Deliberately spans several genres and albums. A playlist whose tracks
    // all share one cover cannot catch a player that is reading the artwork
    // from the playlist instead of from the current track — this one can.
    id: 'aurix-demo-playlist-mixed-tape',
    name: 'AURIX Mixed Tape',
    description: 'A bit of everything in the demo catalogue. Free to stream.',
    genre: 'rock',
    cover: ALBUMS.openSignals.artwork,
    songs: [
      'aurix-demo-amouth-city-of-gold',
      'aurix-demo-goldkette-clementine',
      'aurix-demo-scriabin-prelude-op67',
      'aurix-demo-usaf-4th-street-exit',
      'aurix-demo-spelled-moon-war-of-shadows',
      'aurix-demo-borodin-steppes',
    ],
  },
];

/**
 * The prefix every demo id carries.
 *
 * Exported because it is what makes the seed reversible: `--clear` removes
 * exactly the rows this file created and cannot touch a real import, however
 * the two came to sit in the same collection.
 */
export const DEMO_ID_PREFIX = 'aurix-demo-';
