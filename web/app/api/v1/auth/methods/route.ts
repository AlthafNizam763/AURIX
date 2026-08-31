import { signInMethods } from '@/server/config/env';
import { handler, ok } from '@/server/http/respond';

/**
 * Which ways in this *deployment* offers.
 *
 * Public, and read by the login screen before anyone has signed in — the same
 * reason `GET /theme` is public. A provider whose credentials are absent is
 * reported as unavailable rather than offered and then failing in a browser tab,
 * which is the difference between a button that is not there and a button that
 * is broken.
 *
 * Nothing secret is disclosed. A client id is public by definition and is not
 * returned here either; this is a list of names.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = handler(async () => ok({ methods: signInMethods() }));
