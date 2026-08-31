# Deploying AURIX to Vercel

The backend and the admin portal are one Next.js application in `web/`. This is
what it takes to put it in production and point the app at it.

Read §1 before you start. Two of those decisions are awkward to change once
people have signed in.

---

## 1. Decide these first

| Decision | Why it is hard to change later |
|---|---|
| **Which Atlas region** | Determines the Vercel region you should pin. Moving an Atlas cluster means migrating data. |
| **The production domain** | It is baked into four OAuth provider consoles and into every installed copy of the app. |
| **`JWT_SECRET` / `JWT_REFRESH_SECRET`** | Changing either signs every user out. Fine on day one, disruptive later. |

Everything else can be adjusted with a redeploy.

---

## 2. Region — the one setting this repository cannot choose for you

`vercel.json` deliberately does **not** pin a region.

Every cold start opens a TLS connection to Atlas, and a function in Virginia
talking to a cluster in Mumbai pays that latency on every one. Co-locating them
is the single largest performance decision in this deployment, and it depends on
where your cluster actually is — which the repository has no way to know.

**Find your cluster's region** in Atlas → Database → your cluster → the region
shown under the cluster name.

**Then pin the matching Vercel region.** Either in the dashboard (Project →
Settings → Functions → Function Region) or by adding it to `vercel.json`:

```jsonc
{
  "regions": ["bom1"]   // Mumbai. See vercel.com/docs/regions for the full list.
}
```

Common pairings:

| Atlas region | Vercel region |
|---|---|
| AWS Mumbai (`ap-south-1`) | `bom1` |
| AWS Singapore (`ap-southeast-1`) | `sin1` |
| AWS Frankfurt (`eu-central-1`) | `fra1` |
| AWS Ireland (`eu-west-1`) | `dub1` |
| AWS N. Virginia (`us-east-1`) | `iad1` |
| AWS Oregon (`us-west-2`) | `pdx1` |

Leaving it unset works. It just leaves performance on the table.

---

## 3. Connect the repository

Vercel → Add New → Project → import the repository, then:

| Setting | Value |
|---|---|
| **Root Directory** | **`web`** |
| Framework Preset | Next.js (detected) |
| Build Command | (default) |
| Install Command | (default) |
| Node.js Version | 20.x or later |

**The Root Directory is not optional.** This is a monorepo: `mobile/` is a
Flutter app and `server/` is the Express server being replaced. Pointed at the
repository root, the build finds no `package.json` and fails — or worse, in some
configurations, succeeds and deploys the wrong thing.

---

## 4. Environment variables

Project → Settings → Environment Variables. Set them for **Production** and
**Preview** both, unless noted.

`web/.env.example` is the annotated master list. This is the deployment subset.

### Required — the API will not serve without these

| Variable | Notes |
|---|---|
| `MONGODB_URI` | See §5. Prefer the non-SRV form. |
| `MONGODB_DB` | `aurix` |
| `JWT_SECRET` | `node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"` |
| `JWT_REFRESH_SECRET` | A **different** value, generated the same way |

Use different secrets in Preview than in Production. A preview deployment is a
public URL; a token minted there should not open production.

### Strongly recommended

| Variable | Value | Consequence if unset |
|---|---|---|
| `CORS_ORIGINS` | your production origins, comma separated | Any browser origin may call the API. Mobile builds are unaffected — CORS is a browser mechanism, which a native client ignores. Matters for the Flutter **web** build. |
| `BOOTSTRAP_ADMIN_EMAIL` | the address that should become the first admin | No way to create the first administrator without a database shell. Clear it once that account exists. |
| `PUBLIC_API_URL` | `https://your-project.vercel.app` | **All four social sign-in providers are disabled.** |
| `SMTP_*`, `MAIL_FROM` | your mail provider | Password reset cannot be delivered. In production the token is withheld rather than returned, so the flow fails closed — which is correct, and also means nobody can reset a password. |

### Optional

`ACCESS_TOKEN_TTL`, `REFRESH_TOKEN_DAYS`, `ACTION_TOKEN_MINUTES`,
`MAX_LOGO_BYTES`, `MAX_FONT_BYTES`, `LOG_LEVEL`, `PUBLIC_APP_URL`,
`OAUTH_STATE_MINUTES`, `OAUTH_GRANT_MINUTES`, the `OTP_*` family, the `TWILIO_*`
family, and the four provider credential pairs. All have working defaults or
disable a feature cleanly when absent.

### Deliberately absent

`PORT`, `HOST` — there is no listener. `DNS_SERVERS` — only needed on a network
that refuses SRV lookups, which Vercel's is not. `OTP_DEV_DELIVERY`,
`OTP_DEV_FILE` — removed entirely; serverless has no durable filesystem, and a
plaintext one-time code written to disk was a development affordance that should
not outlive the migration. `NODE_ENV` — set by the platform; do not set it
yourself.

---

## 5. The connection string

**Prefer the non-SRV form.** Atlas → Connect → Drivers → set the driver version
to *Node.js 2.2.12 or later*:

```
mongodb://USER:PASS@shard-00-00.xxx.mongodb.net:27017,shard-00-01...,shard-00-02.../?ssl=true&replicaSet=atlas-xxxxx-shard-0&authSource=admin&retryWrites=true&w=majority
```

Two reasons, one of them performance and one of them correctness:

- `mongodb+srv://` is not an address — it is an instruction to look up a DNS SRV
  record. That is a **DNS round trip on every cold start**, which serverless has
  a great many of.
- Some networks answer ordinary A records and refuse SRV. The symptom is
  `querySrv ECONNREFUSED`, which the driver reports and which therefore reads
  like a database fault. It is not: it happens before a byte reaches Atlas. The
  machine this migration was built on is one of those networks.

`ssl=true` is explicit and must stay. `mongodb+srv://` implies TLS; `mongodb://`
does not, and omitting it is how a connection silently stops being encrypted.

**Percent-encode the password** if it contains any of `: / ? # [ ] @`.

### Atlas network access

Vercel functions do not have stable outbound addresses. Atlas → Network Access →
add `0.0.0.0/0`.

That is less alarming than it looks and is what Atlas documents for serverless:
the allow-list is not the security boundary — the credential and TLS are. Use a
database user scoped to this one database, with `readWrite` and nothing more.

---

## 6. Create the indexes — required, once per environment

```bash
cd web
MONGODB_URI='...' MONGODB_DB=aurix npm run indexes
```

**This is not an optimisation.** The unique indexes *are* the schema:

- `(uid, trackId)` on `likedTracks` is what makes liking a song twice one row
  rather than two.
- `(provider, subject)` on `identities` is what stops one Google account being
  attached to two AURIX users.
- The TTL indexes on the token collections are what expire refresh tokens,
  one-time codes, OAuth state and rate-limit counters. Serverless has nowhere to
  run a cron, so Mongo's TTL monitor is the only thing sweeping them.

A deployment that skips this does not run slowly — it accumulates duplicates no
later index can remove.

The Express server did this at boot. Serverless has no boot, and doing it per
request would race across instances, so it moved to a deliberate step.

---

## 7. Deploy

Push, or click Deploy. You get `https://your-project.vercel.app`.

Check it before going further:

```bash
curl https://your-project.vercel.app/health
# {"ok":true,"service":"aurix-api","db":"up","commit":"a1b2c3d"}
```

`"db":"down"` means the API is running and cannot reach Atlas — check
`MONGODB_URI` and Network Access. The function logs carry the real error;
`ping()` deliberately does not put it in the response.

Then open `https://your-project.vercel.app/admin` and sign in with the
`BOOTSTRAP_ADMIN_EMAIL` account. If it does not exist yet, register it through
the app or `POST /api/v1/auth/register` — the bootstrap check runs at
registration.

---

## 8. Re-register the OAuth callbacks

**This is the longest-lead item and it cannot be automated.** Moving to a new
origin changes all four callback URLs. Until each console is updated, that
provider's sign-in fails at the consent screen.

Set `PUBLIC_API_URL` to the production origin first, then register:

```
https://your-project.vercel.app/api/v1/auth/oauth/google/callback
https://your-project.vercel.app/api/v1/auth/oauth/apple/callback
https://your-project.vercel.app/api/v1/auth/oauth/facebook/callback
https://your-project.vercel.app/api/v1/auth/oauth/github/callback
```

| Provider | Where | Note |
|---|---|---|
| Google | Cloud Console → Credentials → OAuth client → Authorised redirect URIs | Must be a **Web application** client. The exchange happens server-side, so this is a confidential client even though the app is mobile. |
| Apple | Developer → Identifiers → **Services ID** → Return URLs | Also needs **domain verification**, which takes longest. Not the App ID. |
| Facebook | App → Facebook Login → Settings → Valid OAuth Redirect URIs | |
| GitHub | Settings → Developer settings → **OAuth Apps** → Authorization callback URL | An OAuth App, not a GitHub App — the code does not send PKCE for GitHub, and OAuth Apps do not implement it. |

`OAUTH_APP_REDIRECTS` must keep listing `aurix://login-callback`, and it must
match `AURIX_LOGIN_REDIRECT_URI` in the app. That allow-list is load-bearing:
the last hop of a sign-in puts a one-time credential in a URL, so without it
`?redirect_uri=` would make the API hand that credential wherever it was asked.

A provider you have not configured is simply not offered — `GET
/api/v1/auth/methods` reports what works, and the login screen draws buttons only
for those. A missing credential costs one button, not a crash.

---

## 9. Point the app at production

One value in `mobile/.env`:

```diff
- AURIX_API_BASE_URL=http://localhost:3000
+ AURIX_API_BASE_URL=https://your-project.vercel.app
```

Leave `AURIX_API_BASE_URL_ANDROID` and `_WEB` unset in a release build so every
platform uses the one production address. `AurixEndpoints` supplies every path
and needs no edit; `Env.apiBaseUrl` strips a trailing `/api/v1` if you paste the
full API root.

For CI, prefer `--dart-define` over the bundled `.env`:

```bash
flutter build apk --release \
  --dart-define=AURIX_API_BASE_URL=https://your-project.vercel.app
```

Then verify against production the same way the migration did:

```bash
cd mobile
flutter test test/live --dart-define=AURIX_LIVE_API=https://your-project.vercel.app
```

That drives the real Dart client against the real deployment. It creates and
deletes a throwaway account, and leaves one catalogue song behind by design —
see the note in the suite.

---

## 10. Retire the old server

Only after §9 passes against production.

`server/` is still present and still runnable. Keep it until you are satisfied,
then delete it and `server-backup/`. Git holds the history either way.

**Before you do**: `server/src/services/tokens.js` has a bug the port fixed. Two
refresh tokens issued for one account in the same second are byte-identical,
because the payload is `{sub, typ}` with one-second `iat`/`exp` resolution. The
unique index turns that into a 500 on an ordinary sign-in; without the index it
would hand two devices the same token. The Next.js version adds a random `jti`.
If you keep the old server running for any length of time, port that fix.

---

## 11. When something is wrong

| Symptom | Cause |
|---|---|
| Build fails, no `package.json` | Root Directory is not `web`. |
| `/health` → `db: down` | `MONGODB_URI`, or Atlas Network Access. Real error is in the function logs. |
| `querySrv ECONNREFUSED` | SRV lookup refused. Use the non-SRV connection string — §5. |
| Every request 500s with `internal` | Usually a missing `JWT_SECRET`. The message names it; validation happens on first use, not at build. |
| Duplicate liked songs, or a second account for one Google login | `npm run indexes` was never run — §6. |
| Sign-in works, social sign-in does not | `PUBLIC_API_URL` unset, or callbacks not re-registered — §8. |
| "Sign-in did not complete" in the browser | The `state` expired or was replayed. Ten minutes by default. |
| Password reset silently does nothing | No SMTP. Production fails closed rather than returning the token. |
| Font upload fails around 4 MB | Vercel rejects bodies over 4.5 MB before the function runs. `MAX_FONT_BYTES` defaults to 3.5 MB so the failure stays inside the API. |
| Admin portal bounces to login repeatedly | Cookie is `secure` in production — the deployment must be https. |
| Flutter **web** build fails every call, but `curl` works | The origin is not in `CORS_ORIGINS`. Native builds are unaffected. |
| Rate limits feel far too permissive | Counters are in Mongo, not memory. If `rateLimits` has no indexes, run §6. |
