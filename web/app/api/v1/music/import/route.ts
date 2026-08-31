import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { credentialFor, requireCredential } from '@/server/services/music/connections';
import { importPlaylist } from '@/server/services/music/import';
import { parsePlaylistLink } from '@/server/services/music/links';
import { spotifyFetcher } from '@/server/services/music/spotify';
import type { PlaylistFetcher } from '@/server/services/music/types';
import { youtubeFetcher } from '@/server/services/music/youtube';
import { env } from '@/server/config/env';
import { providerAuthRequired } from '@/server/utils/errors';

/**
 * Import a playlist from a pasted link.
 *
 * ```
 * link ─→ provider + playlist id      links.ts, never taken from the body
 *      ─→ connection?                 only where the provider actually needs one
 *      ─→ provider API                metadata, then items, paged to the end
 *      ─→ normalise                   one shape, whichever provider it came from
 *      ─→ MongoDB                     deduped on provider + provider id
 *      → the AURIX playlist
 * ```
 *
 * ## Authorization is demanded when it is needed, and not before
 *
 * This is the requirement the whole feature turns on, so it is worth stating
 * where it lives: the two providers need different things and the route asks for
 * different things.
 *
 *  * **Spotify** has no unauthenticated read path — every Web API call needs a
 *    token, and since February 2026 a playlist's *items* need a token belonging
 *    to that playlist's owner or a collaborator. So a connection is required up
 *    front, and its absence is reported as `provider_auth_required`, which the
 *    app renders as a "Connect Spotify" button rather than an error.
 *  * **YouTube** serves a public playlist to a caller holding only an API key.
 *    So the connection is used *if there is one* and skipped if there is not,
 *    and the user is asked to connect only when the key gets a refusal — which
 *    is what a private or unlisted playlist looks like from outside.
 *
 * The user never authorizes a provider to import a playlist that did not need
 * it, and never sees "contents unavailable" for one that did.
 *
 * ## Why the link is parsed here rather than trusted
 *
 * A route that accepted `{ provider, playlistId }` would let a caller name any
 * provider for any id — and the connection lookup, the ownership check and the
 * document id all key off exactly that pair. The link is the input; the pair is
 * derived.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  /** A Spotify or YouTube playlist link, in any of the forms `links.ts` accepts. */
  url: z.string().trim().min(1).max(2048),
});

const FETCHERS: Record<string, PlaylistFetcher> = {
  spotify: spotifyFetcher,
  youtube: youtubeFetcher,
};

export const POST = withAuth(async (request, { auth }) => {
  // An import is a dozen-plus outbound requests and a burst of writes. Rate
  // limited on the same bucket as the other expensive authenticated routes so a
  // loop in a client cannot turn into a loop against Spotify's API, which would
  // earn this deployment a throttle affecting every user.
  const headers = await enforce(LIMITS.oauthStart, request);

  const input = await body(request, schema);
  const link = parsePlaylistLink(input.url);
  const fetcher = FETCHERS[link.provider]!;

  // Spotify: required. YouTube: used when present, and the fetcher falls back to
  // the API key when it is not. See the note above.
  const credential =
    link.provider === 'spotify'
      ? await requireCredential(auth.uid, 'spotify')
      : await credentialFor(auth.uid, 'youtube');

  if (link.provider === 'youtube' && !credential && !env.music.youtube.apiKey) {
    // No key configured and no connection: there is no way to read anything,
    // and connecting is the only remedy the user has.
    throw providerAuthRequired('YouTube');
  }

  const fetched = await fetcher.fetch(link.playlistId, credential);

  // The importer's name is stored on the shared playlist as provenance — it is
  // what the library shows as "Imported by". Read from the account rather than
  // taken from the request, for the same reason the uid is.
  const users = await collections.users();
  const user = await users.findOne({ uid: auth.uid }, { projection: { name: 1 } });

  const result = await importPlaylist({
    uid: auth.uid,
    importerName: user?.name ?? '',
    provider: link.provider,
    fetched,
  });

  return ok(result, result.created ? 201 : 200, headers);
});
