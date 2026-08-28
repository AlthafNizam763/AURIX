import express from 'express';
import rateLimit from 'express-rate-limit';

import { env } from '../config/env.js';
import { optionalAuth } from '../middleware/auth.js';
import { validate, z } from '../middleware/validate.js';
import { signInMethodsFor, resolveSocial } from '../services/identities.js';
import {
  beginFlow,
  callbackUrlFor,
  deadEndPage,
  issueGrant,
  logProviderFailure,
  peekGrant,
  redirectWith,
  takeGrant,
  takeState,
} from '../services/oauth/flow.js';
import { PROVIDER_IDS, providerLabel, requireProvider } from '../services/oauth/providers.js';
import { maskEmail } from '../services/phone.js';
import { buildSession } from '../services/session.js';
import { requireUser } from '../services/users.js';
import { route } from '../utils/async.js';
import { invalidAuthState, unauthorized } from '../utils/errors.js';

/**
 * Google, Apple, Facebook and GitHub.
 *
 * Mounted at `/api/v1/auth/oauth`. Three endpoints serve all four providers,
 * because everything provider-specific is behind the uniform interface in
 * `services/oauth/providers.js` and everything flow-specific is in
 * `services/oauth/flow.js` — which is where the diagram explaining these three
 * routes lives.
 *
 *   POST /:provider/start      open a transaction, get a URL to show the user
 *   GET|POST /:provider/callback   where the provider returns  (SECRETS USED)
 *   POST /exchange             redeem the grant for a session or a challenge
 *
 * ## Why `/callback` answers with a redirect and never with JSON
 *
 * Its caller is a browser that the provider navigated, not the app. The app is
 * sitting in `flutter_web_auth_2` waiting for its own redirect URI to be hit,
 * and a JSON body would leave it waiting until it timed out. So every path
 * through that handler ends in a 302 back to the app — success and failure
 * alike — and the only exception is a callback with no valid state, where
 * there is no address that has been proved safe to redirect to.
 */
const router = express.Router();

const providerParam = z.object({ provider: z.enum(PROVIDER_IDS) });

const startLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: env.isProduction ? 30 : 300,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: { code: 'rate_limited', message: 'Too many sign-in attempts. Try again shortly.' } },
});

const exchangeLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: env.isProduction ? 60 : 600,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: { code: 'rate_limited', message: 'Too many attempts. Try again shortly.' } },
});

// ---------------------------------------------------------------------------
// 1. Start
// ---------------------------------------------------------------------------

router.post(
  '/:provider/start',
  startLimiter,
  optionalAuth,
  validate({
    params: providerParam,
    body: z.object({
      /** Where this server should send the browser at the end. Allow-listed. */
      redirectUri: z.string().trim().min(3).max(2048),
      /** `link` adds the provider to the session already open. */
      intent: z.enum(['signIn', 'link']).default('signIn'),
      device: z.string().max(120).optional(),
    }),
  }),
  route(async (req, res) => {
    const { intent } = req.body;
    if (intent === 'link' && !req.user?.uid) throw unauthorized();

    // The uid is taken from the verified bearer token and written into the
    // state row here. Nothing that comes back through the browser can change
    // which account a link lands on — the callback reads it out of the state,
    // never out of a parameter.
    const flow = await beginFlow({
      providerId: req.params.provider,
      redirectUri: req.body.redirectUri,
      intent,
      actorUid: req.user?.uid,
      device: req.body.device,
    });

    res.json(flow);
  }),
);

// ---------------------------------------------------------------------------
// 2. Callback — the only place a client secret is used
// ---------------------------------------------------------------------------

/**
 * Apple POSTs here as `application/x-www-form-urlencoded`; the rest use GET.
 *
 * Parsed on this route alone rather than app-wide, so the one endpoint in
 * AURIX that accepts a form body is the one that has to.
 */
const formBody = express.urlencoded({ extended: false, limit: '64kb' });

async function handleCallback(req, res) {
  const providerId = req.params.provider;
  const params = { ...(req.query ?? {}), ...(req.body ?? {}) };
  const state = typeof params.state === 'string' ? params.state : '';

  // The state is consumed first and unconditionally. It is what says where
  // this flow is allowed to end, so nothing below can redirect anywhere until
  // it has been verified — and consuming it is what makes a replayed callback
  // fail rather than mint a second grant.
  let transaction;
  try {
    transaction = await takeState(state);
  } catch {
    return res
      .status(400)
      .type('html')
      .send(
        deadEndPage(
          'This sign-in link has already been used, or it expired while the ' +
            'consent screen was open.',
        ),
      );
  }

  const back = transaction.redirectUri;

  try {
    if (transaction.provider !== providerId) throw invalidAuthState();

    // The user pressed Cancel, or the provider refused. Not an error worth a
    // log line — it is the second most common outcome of an OAuth screen.
    if (typeof params.error === 'string' && params.error.length > 0) {
      return res.redirect(
        redirectWith(back, {
          error: params.error,
          error_description: String(params.error_description ?? ''),
          state,
        }),
      );
    }

    const code = typeof params.code === 'string' ? params.code : '';
    if (code.length === 0) throw invalidAuthState();

    const provider = requireProvider(providerId);

    // Here, and nowhere else in AURIX: the authorization code is traded for
    // provider tokens using this deployment's client secret. Neither the code
    // nor the tokens nor the secret ever leaves this process.
    const tokens = await provider.exchange({
      code,
      redirectUri: callbackUrlFor(providerId),
      verifier: transaction.verifier,
    });

    const profile = await provider.profile(tokens, {
      nonce: transaction.nonce,
      // Apple's display name arrives beside the code, once, and never again.
      formBody: req.body,
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
            // The profile is carried rather than re-fetched: the authorization
            // code is spent, and asking the provider again would need a fresh
            // consent round trip after the user has already given one.
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

    return res.redirect(redirectWith(back, { code: grant, state }));
  } catch (error) {
    logProviderFailure(providerId, error);
    // The app gets a code it can map to a sentence; the provider's own
    // diagnosis stays in the log, where it is useful and not disclosed.
    return res.redirect(
      redirectWith(back, {
        error: error?.code ?? 'provider_error',
        error_description: error?.message ?? 'That sign-in could not be completed.',
        state,
      }),
    );
  }
}

router.get('/:provider/callback', validate({ params: providerParam }), route(handleCallback));
router.post(
  '/:provider/callback',
  formBody,
  validate({ params: providerParam }),
  route(handleCallback),
);

// ---------------------------------------------------------------------------
// 3. Exchange — the app redeems its grant
// ---------------------------------------------------------------------------

/**
 * Two possible answers, and the client branches on `linkRequired`.
 *
 * A session is the ordinary outcome and is byte-for-byte the payload the
 * password and phone routes return. The alternative is not an error: it means
 * the provider asserted a verified address that already belongs to an AURIX
 * account, and the caller has to prove they own it before the two are joined.
 * See `services/identities.js` for why that is a challenge and not an
 * automatic merge.
 */
router.post(
  '/exchange',
  exchangeLimiter,
  validate({
    body: z.object({
      code: z.string().trim().min(1).max(512),
      device: z.string().max(120).optional(),
    }),
  }),
  route(async (req, res) => {
    const record = await peekGrant(req.body.code);

    if (record.kind === 'session') {
      // Spent atomically. The peek above only decided which branch to take;
      // this is the operation that makes the grant single-use.
      await takeGrant(req.body.code, 'session');
      const user = await requireUser(record.uid);
      return res.json(
        await buildSession(user, {
          device: req.body.device ?? record.payload?.device,
          provider: record.provider,
          created: record.payload?.created === true,
          linked: record.payload?.linked === true,
        }),
      );
    }

    const owner = await requireUser(record.uid);
    res.json({
      linkRequired: true,
      // The same value. The grant stays live because the challenge is a
      // conversation — ask for a code, then answer it — and is destroyed when
      // the link completes, when the attempts run out, or when its TTL does.
      linkToken: req.body.code,
      provider: record.provider,
      providerLabel: providerLabel(record.provider),
      // Masked. The caller has not yet proved anything about this account, so
      // they are told just enough to recognise it as their own.
      email: maskEmail(owner.email),
      hasPassword: typeof owner.passwordHash === 'string' && owner.passwordHash.length > 0,
      methods: await signInMethodsFor(owner),
      expiresInSeconds: env.oauthGrantMinutes * 60,
    });
  }),
);

export default router;
