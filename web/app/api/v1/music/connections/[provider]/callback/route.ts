import type { RouteContext } from '@/server/http/respond';
import { handler } from '@/server/http/respond';
import {
  callbackUrlFor,
  storeConnection,
  takeState,
} from '@/server/services/music/connections';
import { requireMusicProvider } from '@/server/services/music/providers';
import { deadEndPage, redirectWith } from '@/server/services/oauth/flow';
import { log } from '@/server/utils/logger';

/**
 * Where Spotify or Google sends the browser back after consent.
 *
 * Answers a redirect rather than JSON, because its caller is a browser. It is
 * also the only place in the music-import feature that touches a client secret,
 * by way of `provider.exchange` — which is exactly the property §11 asks for.
 *
 * ## What crosses back to the app
 *
 * `aurix://…?provider=spotify&status=connected`. **No token, and no code.** By
 * the time this redirects, the connection is already stored server-side against
 * the uid that started the flow; the app's next request simply finds it. That is
 * a deliberate difference from the sign-in callback, which must hand back a
 * single-use grant because the app needs a session out of it. Here the app needs
 * nothing, so nothing is put in the URL.
 *
 * ## Nothing here trusts a parameter it has not verified
 *
 * `state` is consumed from the database — a replayed callback finds nothing —
 * and both the uid and the app redirect come out of that stored record rather
 * than out of the request. A callback with no usable state has nowhere safe to
 * go, so it stops on a dead-end page rather than redirecting to an address it
 * has just failed to verify.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

function stop(message: string, status = 400): Response {
  return new Response(deadEndPage(message), {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}

export const GET = handler<{ provider: string }>(async (request, context) => {
  const { provider: providerId } = await context.params;
  const query = new URL(request.url).searchParams;
  const state = query.get('state') ?? '';

  let transaction;
  try {
    transaction = await takeState(state);
  } catch {
    return stop(
      'This connection link has already been used, or it expired while the ' +
        'consent screen was open.',
    );
  }

  const back = transaction.redirectUri;

  // The provider named in the path must be the one the flow was started for.
  // Without this check a state issued for Spotify could be redeemed at the
  // Google callback, which would exchange the code with the wrong client
  // credentials and store the result under the wrong provider.
  if (transaction.provider !== providerId) {
    log.warn(
      `Music callback provider mismatch: state was ${transaction.provider}, path was ${providerId}`,
      'music',
    );
    return Response.redirect(
      redirectWith(back, { provider: transaction.provider, status: 'error', reason: 'mismatch' }),
      302,
    );
  }

  // The user pressed Cancel, or the provider refused. A normal outcome, not an
  // error — reported back so the app can stop its spinner and say so.
  const denied = query.get('error');
  if (denied) {
    log.info(`${providerId} connection declined: ${denied}`, 'music');
    return Response.redirect(
      redirectWith(back, { provider: providerId, status: 'declined', reason: denied }),
      302,
    );
  }

  const code = query.get('code') ?? '';
  if (!code) {
    return Response.redirect(
      redirectWith(back, { provider: providerId, status: 'error', reason: 'no_code' }),
      302,
    );
  }

  try {
    const provider = requireMusicProvider(providerId);

    const tokens = await provider.exchange({
      code,
      redirectUri: callbackUrlFor(provider.id),
      verifier: transaction.verifier,
    });

    // Named before storing, so the import screen can say "Connected as …" and
    // the ownership error can say which account AURIX is holding. A failure to
    // identify is not a failure to connect — the tokens are good, and a nameless
    // connection still imports.
    let account = { id: '', name: '' };
    try {
      account = await provider.identify(tokens.accessToken);
    } catch (error) {
      log.warn(`Connected to ${providerId} but could not name the account`, 'music', error);
    }

    await storeConnection({
      uid: transaction.uid,
      provider: provider.id,
      tokens,
      account,
    });

    return Response.redirect(
      redirectWith(back, {
        provider: providerId,
        status: 'connected',
        ...(account.name ? { account: account.name } : {}),
      }),
      302,
    );
  } catch (error) {
    // The provider's own diagnosis routinely names the client id and the exact
    // misconfiguration — invaluable in a log, unacceptable in a redirect the
    // user can read. So the detail is logged and the URL carries a code.
    log.error(
      `${providerId} connection failed: ${error instanceof Error ? error.message : String(error)}`,
      'music',
      error,
    );
    return Response.redirect(
      redirectWith(back, { provider: providerId, status: 'error', reason: 'exchange_failed' }),
      302,
    );
  }
});
