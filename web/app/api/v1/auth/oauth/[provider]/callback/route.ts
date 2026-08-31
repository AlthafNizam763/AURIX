import type { RouteContext } from '@/server/http/respond';
import {
  callbackUrlFor,
  deadEndPage,
  issueGrant,
  logProviderFailure,
  redirectWith,
  takeState,
} from '@/server/services/oauth/flow';
import { isProviderId, requireProvider } from '@/server/services/oauth/providers';
import { resolveSocial } from '@/server/services/identities';
import { invalidAuthState } from '@/server/utils/errors';

/**
 * Where the provider sends the browser back.
 *
 * The only handler in the API that answers with HTML or a redirect rather than
 * JSON — because its caller is a browser, not the app. It is also the only one
 * that touches a client secret, by way of `provider.exchange`.
 *
 * ## Two verbs, and why
 *
 * Google, Facebook and GitHub redirect here with a query string. **Apple POSTs**
 * a form body, which is what requesting the `name` and `email` scopes forces —
 * and that form body is the one and only place Apple ever discloses the user's
 * name. Both verbs run the identical handler; the form fields are parsed and
 * handed to `provider.profile` so that name survives.
 *
 * ## Nothing here trusts a parameter it has not verified
 *
 * `state` is consumed from the database — a second callback with the same value
 * finds nothing — and the app redirect comes from that stored record, never from
 * the request. A callback with no usable state has nowhere safe to go, so it
 * stops on a dead-end page rather than redirecting to an address it has just
 * failed to verify.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/** Merges the query string with a form body, when there is one. */
async function parameters(request: Request): Promise<Record<string, string>> {
  const query = Object.fromEntries(new URL(request.url).searchParams.entries());

  if (request.method !== 'POST') return query;

  try {
    const form = await request.formData();
    const fields: Record<string, string> = {};
    for (const [key, value] of form.entries()) {
      if (typeof value === 'string') fields[key] = value;
    }
    return { ...query, ...fields };
  } catch {
    return query;
  }
}

async function handleCallback(
  request: Request,
  context: RouteContext<{ provider: string }>,
): Promise<Response> {
  const { provider: providerId } = await context.params;
  const params = await parameters(request);
  const state = typeof params.state === 'string' ? params.state : '';

  let transaction;
  try {
    transaction = await takeState(state);
  } catch {
    return new Response(
      deadEndPage(
        'This sign-in link has already been used, or it expired while the ' +
          'consent screen was open.',
      ),
      { status: 400, headers: { 'Content-Type': 'text/html; charset=utf-8' } },
    );
  }

  const back = transaction.redirectUri;

  try {
    if (transaction.provider !== providerId) throw invalidAuthState();

    if (typeof params.error === 'string' && params.error.length > 0) {
      // The user declined, or the provider refused. Carried back to the app so
      // it can say so, rather than hanging on a browser that never returns.
      return Response.redirect(
        redirectWith(back, {
          error: params.error,
          error_description: String(params.error_description ?? ''),
          state,
        }),
        302,
      );
    }

    const code = typeof params.code === 'string' ? params.code : '';
    if (code.length === 0) throw invalidAuthState();
    if (!isProviderId(providerId)) throw invalidAuthState();

    const provider = requireProvider(providerId);

    const tokens = await provider.exchange({
      code,
      redirectUri: callbackUrlFor(providerId),
      verifier: transaction.verifier,
    });

    const profile = await provider.profile(tokens, {
      nonce: transaction.nonce,
      formBody: params,
    });

    const outcome = await resolveSocial({
      provider: providerId,
      profile,
      intent: transaction.intent,
      actorUid: transaction.uid,
    });

    const grant =
      outcome.kind === 'link'
        ? await issueGrant({
            kind: 'link',
            provider: providerId,
            uid: outcome.user.uid,
            payload: { profile, device: transaction.device },
          })
        : await issueGrant({
            kind: 'session',
            provider: providerId,
            uid: outcome.user.uid,
            payload: {
              created: outcome.created === true,
              linked: outcome.linked === true,
              device: transaction.device,
            },
          });

    return Response.redirect(redirectWith(back, { code: grant, state }), 302);
  } catch (error) {
    logProviderFailure(providerId, error);
    return Response.redirect(
      redirectWith(back, {
        error: (error as { code?: string })?.code ?? 'provider_error',
        error_description:
          (error as Error)?.message ?? 'That sign-in could not be completed.',
        state,
      }),
      302,
    );
  }
}

export const GET = handleCallback;
export const POST = handleCallback;
