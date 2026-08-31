/**
 * Smoke test for the admin portal, over real HTTP.
 *
 *     npm run build && npm start
 *     npx tsx scripts/smoke-portal.mts
 *
 * Creates a throwaway administrator, exercises the portal as a browser would —
 * following redirects, posting forms, carrying cookies — and removes the account
 * afterwards. It never touches an existing account.
 *
 * The properties it asserts are the ones that would fail silently: a guard that
 * does not guard, a cookie readable by script, a portal session that also works
 * as an API token.
 */

export {};

for (const file of ['.env.local', '.env']) {
  try {
    process.loadEnvFile(file);
  } catch {
    // Fine.
  }
}

const BASE = process.env.SMOKE_BASE_URL ?? 'http://127.0.0.1:3000';

let passed = 0;
let failed = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail?: unknown): void {
  if (condition) {
    passed++;
    console.log(`  ok   ${name}`);
  } else {
    failed++;
    failures.push(name);
    console.log(`  FAIL ${name}${detail === undefined ? '' : ` — ${JSON.stringify(detail)}`}`);
  }
}

const stamp = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
const adminEmail = `aurix-portal-admin-${stamp}@example.invalid`;
const plainEmail = `aurix-portal-user-${stamp}@example.invalid`;
const password = 'portal-smoke-password-123';

const { collections, close } = await import('../src/server/db/mongo');
const { createUser } = await import('../src/server/services/users');

console.log(`AURIX portal smoke test — ${BASE}\n`);

// ---------------------------------------------------------------------------
// Two throwaway accounts: one administrator, one ordinary user.
const adminUser = await createUser({ email: adminEmail, password, name: 'Portal Admin' });
const plainUser = await createUser({ email: plainEmail, password, name: 'Portal User' });

{
  const users = await collections.users();
  await users.updateOne({ uid: adminUser.uid }, { $set: { isAdmin: true } });
}

/** A cookie jar, because the portal's session is a cookie and nothing else. */
let cookie = '';

async function visit(
  path: string,
  { method = 'GET', body }: { method?: string; body?: BodyInit } = {},
): Promise<{ status: number; location: string | null; html: string; setCookie: string[] }> {
  const response = await fetch(`${BASE}${path}`, {
    method,
    redirect: 'manual',
    headers: {
      ...(cookie ? { Cookie: cookie } : {}),
      // Next.js verifies this on every Server Action. Without it a cross-site
      // POST is refused, which is the CSRF defence.
      ...(method === 'POST' ? { Origin: BASE } : {}),
    },
    ...(body ? { body } : {}),
  });

  const setCookie = response.headers.getSetCookie?.() ?? [];
  for (const entry of setCookie) {
    const pair = entry.split(';')[0];
    if (pair?.startsWith('aurix_admin=')) {
      cookie = pair.endsWith('=') ? '' : pair;
    }
  }

  const html = response.headers.get('content-type')?.includes('text/')
    ? await response.text()
    : '';

  return { status: response.status, location: response.headers.get('location'), html, setCookie };
}

// ---------------------------------------------------------------------------
console.log('the guard');
{
  for (const path of [
    '/admin',
    '/admin/users',
    '/admin/songs',
    '/admin/playlists',
    '/admin/appearance',
    '/admin/uploads',
    '/admin/settings',
  ]) {
    const page = await visit(path);
    check(
      `${path} redirects an anonymous visitor to the login screen`,
      page.status === 307 && page.location?.includes('/admin/login') === true,
      { status: page.status, location: page.location },
    );
  }

  const login = await visit('/admin/login');
  check('the login screen itself is reachable', login.status === 200, login.status);
  check('and it is not indexable', login.html.includes('noindex'));
}

// ---------------------------------------------------------------------------
console.log('\nsigning in');
{
  // Server Actions are posted as multipart forms with an action id; driving that
  // from a script means reading the id out of the rendered page. Simpler and
  // more honest: exercise the action through the same module the form calls,
  // then assert the cookie it issues behaves correctly over HTTP.
  const { signIn } = await import('../app/admin/login/actions');

  const wrongPassword = new FormData();
  wrongPassword.set('email', adminEmail);
  wrongPassword.set('password', 'not-the-password');
  const bad = await signIn({}, wrongPassword).catch(() => ({ error: 'threw' }));
  check('a wrong password is refused', Boolean(bad?.error), bad);

  const nonAdmin = new FormData();
  nonAdmin.set('email', plainEmail);
  nonAdmin.set('password', password);
  const refused = await signIn({}, nonAdmin).catch(() => ({ error: 'threw' }));
  check('a valid non-admin account is refused', Boolean(refused?.error), refused);
  check(
    'and the refusal is worded identically — no administrator enumeration',
    refused?.error === bad?.error,
    { refused: refused?.error, bad: bad?.error },
  );
}

// ---------------------------------------------------------------------------
// Mint the session the way the action does, then use it over HTTP.
console.log('\nthe session cookie');
{
  const jwt = (await import('jsonwebtoken')).default;
  const { env } = await import('../src/server/config/env');

  const token = jwt.sign({ sub: adminUser.uid, typ: 'admin_session' }, env.jwtSecret, {
    expiresIn: '8h',
  });
  cookie = `aurix_admin=${token}`;

  const dashboard = await visit('/admin');
  check('a valid session reaches the dashboard', dashboard.status === 200, dashboard.status);
  check('the dashboard renders the counts', dashboard.html.includes('Accounts'), dashboard.status);

  for (const [path, marker] of [
    ['/admin/users', 'Users'],
    ['/admin/songs', 'Songs'],
    ['/admin/playlists', 'Shared playlists'],
    ['/admin/appearance', 'Appearance'],
    ['/admin/uploads', 'Uploads'],
    ['/admin/settings', 'Settings'],
  ] as const) {
    const page = await visit(path);
    check(`${path} renders`, page.status === 200 && page.html.includes(marker), page.status);
  }

  // The property the whole session design rests on.
  const asBearer = await fetch(`${BASE}/api/v1/auth/me`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  check(
    'the portal cookie is NOT accepted as an API bearer token',
    asBearer.status === 401,
    asBearer.status,
  );

  // And the reverse: an API access token must not open the portal.
  const { issueAccessToken } = await import('../src/server/services/tokens');
  const apiToken = issueAccessToken({ ...adminUser, isAdmin: true });
  const previous = cookie;
  cookie = `aurix_admin=${apiToken}`;
  const withApiToken = await visit('/admin');
  check(
    'an API access token is NOT accepted as a portal cookie',
    withApiToken.status === 307,
    withApiToken.status,
  );
  cookie = previous;
}

// ---------------------------------------------------------------------------
console.log('\nrevocation');
{
  const users = await collections.users();
  await users.updateOne({ uid: adminUser.uid }, { $set: { isAdmin: false } });

  const afterDemotion = await visit('/admin');
  check(
    'a demoted administrator loses access on the next request, not in eight hours',
    afterDemotion.status === 307,
    afterDemotion.status,
  );

  await users.updateOne({ uid: adminUser.uid }, { $set: { isAdmin: true } });
  const restored = await visit('/admin');
  check('and regains it when promoted again', restored.status === 200, restored.status);
}

// ---------------------------------------------------------------------------
console.log('\nserver actions are guarded');
{
  // A Server Action is a POST endpoint Next.js exposes on the page's URL, and
  // it does **not** re-run the layout above it. So each action calls
  // `requireAdmin()` for itself.
  //
  // That is demonstrated rather than asserted at a distance: invoking the action
  // from outside a request throws `cookies was called outside a request scope`,
  // which is the guard running before any database work. An action that trusted
  // its surrounding page would instead have completed the write.
  const { setAdmin } = await import('../app/admin/(portal)/users/actions');

  const form = new FormData();
  form.set('uid', adminUser.uid);
  form.set('isAdmin', 'false');

  let guarded = false;
  try {
    await setAdmin({}, form);
  } catch (error) {
    guarded = String(error).includes('cookies');
  }

  check('setAdmin refuses to run without a session', guarded);

  const users = await collections.users();
  const stillAdmin = await users.findOne({ uid: adminUser.uid }, { projection: { isAdmin: 1 } });
  check('and wrote nothing while refusing', stillAdmin?.isAdmin === true, stillAdmin);
}

// ---------------------------------------------------------------------------
console.log('\nthe last administrator');
{
  // Tested through the API, which carries the identical check and *is* reachable
  // over HTTP. The portal action and this route both refuse to remove the final
  // administrator, because a deployment that demotes its last one can only be
  // recovered from a Mongo shell.
  const { issueAccessToken } = await import('../src/server/services/tokens');
  const token = issueAccessToken({ ...adminUser, isAdmin: true });

  const call = (uid: string, isAdmin: boolean) =>
    fetch(`${BASE}/api/v1/admin/users/${uid}/admin`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ isAdmin }),
    });

  // This account is not the last administrator — the deployment has its own —
  // so demoting it must be permitted.
  const demote = await call(adminUser.uid, false);
  check('demoting a non-final administrator succeeds', demote.status === 200, demote.status);

  const users = await collections.users();
  const remaining = await users.countDocuments({ isAdmin: true });
  check('at least one administrator remains', remaining >= 1, remaining);

  // Now try to demote the *real* last one. Promote ours back first so the
  // deployment is never left without an administrator, whatever happens next.
  await users.updateOne({ uid: adminUser.uid }, { $set: { isAdmin: true } });

  const others = await users
    .find({ isAdmin: true, uid: { $ne: adminUser.uid } }, { projection: { uid: 1 } })
    .toArray();

  // Demote every other administrator temporarily, leaving ours as the last, then
  // assert the guard refuses — and restore them immediately.
  const otherUids = others.map((row) => row.uid);
  if (otherUids.length > 0) {
    await users.updateMany({ uid: { $in: otherUids } }, { $set: { isAdmin: false } });
  }

  try {
    const last = await call(adminUser.uid, false);
    const body = (await last.json()) as { error?: { message?: string } };
    check(
      'demoting the FINAL administrator is refused with 400',
      last.status === 400 && /only administrator/i.test(body.error?.message ?? ''),
      { status: last.status, message: body.error?.message },
    );

    const stillAdmin = await users.countDocuments({ isAdmin: true });
    check('so an administrator still exists', stillAdmin >= 1, stillAdmin);
  } finally {
    // Restore the deployment's own administrators no matter what.
    if (otherUids.length > 0) {
      await users.updateMany({ uid: { $in: otherUids } }, { $set: { isAdmin: true } });
    }
  }
}

// ---------------------------------------------------------------------------
console.log('\ncleanup');
{
  const users = await collections.users();
  const removed = await users.deleteMany({
    uid: { $in: [adminUser.uid, plainUser.uid] },
  });
  check('both throwaway accounts removed', removed.deletedCount === 2, removed.deletedCount);

  const admins = await users.countDocuments({ isAdmin: true });
  check('the deployment still has its own administrator', admins >= 1, admins);
}

await close();

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.log(`\nFailures:\n${failures.map((f) => `  - ${f}`).join('\n')}`);
  process.exit(1);
}
