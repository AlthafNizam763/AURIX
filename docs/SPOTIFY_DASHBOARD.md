# Spotify Developer Dashboard — what AURIX needs

Verified against Spotify's official documentation in **August 2026**. Spotify
has changed the rules for developer apps three times since late 2024, and most
guidance you will find online predates all three. Every claim below links to
the page it came from; anything unverified is labelled as such.

---

## The short version

| Setting | Value |
| --- | --- |
| Flow | Authorization Code **with PKCE** |
| Client secret | **None.** Never add one to this app |
| Client ID | `.env` → `SPOTIFY_CLIENT_ID` |
| Redirect URI (Android/iOS) | `aurix://auth-callback` |
| Redirect URI (Web, local) | `http://127.0.0.1:8080/auth.html` |
| Redirect URI (Web, deployed) | `https://<your-domain>/auth.html` |
| APIs to tick | **Web API** only |
| User Management | Every account that signs in, up to 5 |
| Owner account | Must hold active **Spotify Premium** |

---

## 1. Redirect URIs

Register **one entry per platform you build for**. Spotify matches the
redirect URI exactly — not by prefix, not case-insensitively.

### Rules currently in force

From [Redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri):

* "Use HTTPS for your redirect URI, unless you are using a loopback address,
  when HTTP is permitted."
* "If you are using a loopback address, use the explicit IPv4 or IPv6, like
  `http://127.0.0.1:PORT` or `http://[::1]:PORT`."
* **"`localhost` is not allowed as redirect URI."**

These took effect for new apps on 9 April 2025 and for all apps in the
migration completed 27 November 2025, which also removed the implicit grant
flow and all plain-HTTP redirect URIs. See
[the migration reminder](https://developer.spotify.com/blog/2025-10-14-reminder-oauth-migration-27-nov-2025).

### Custom schemes are still fine

`aurix://auth-callback` is **not** affected by the HTTPS requirement. From
[the February 2025 security post](https://developer.spotify.com/blog/2025-02-12-increasing-the-security-requirements-for-integrating-with-spotify):

> "Redirects using a custom scheme will still be supported, but we recommend
> developers to use HTTPS redirects where possible."

That post lists `com.example://callback` as remaining supported unchanged.

### One formatting caveat worth knowing

The [Apps concept page](https://developer.spotify.com/documentation/web-api/concepts/apps)
lists rules for custom-scheme redirect URIs, one of which is:

> "Include a path after the first pair of forward slashes."

`aurix://auth-callback` has a *host* (`auth-callback`) but no path segment, so
it does not strictly satisfy that wording. It is kept as-is because it is what
the app currently ships and registers, and because the rule is not enforced at
the API level today. **If Spotify ever rejects it**, the fix is mechanical —
switch to `aurix://auth/callback` in all four places listed under "Changing the
URL scheme" in the README, and update the dashboard entry.

### The web entry

Flutter Web cannot use a custom scheme: nothing can redirect a browser tab to
`aurix://`. AURIX serves [`web/auth.html`](../web/auth.html) as the landing
page instead, which hands the callback URL back to `flutter_web_auth_2` via
`postMessage`.

`SPOTIFY_REDIRECT_URI_WEB` is pinned to `http://127.0.0.1:8080/auth.html` in
`.env`, and web must be run on a matching port:

```bash
flutter run -d chrome --web-port 8080
```

**Do not leave it blank for local development.** Blank means "derive it from
the serving origin", and `flutter run -d chrome` takes a random OS port unless
told otherwise — giving `http://127.0.0.1:51066/auth.html` on one launch and
something else on the next. Neither can be registered, and Spotify answers
`redirect_uri: Not matching configuration`.

One wrinkle worth knowing: Flutter serves on `localhost` unless
`--web-hostname 127.0.0.1` is passed, while Spotify requires the literal
`127.0.0.1` in the redirect URI. A browser treats those as different origins,
so the callback page would not be able to message the tab that opened it.
AURIX handles this — `web/auth.html` posts to both loopback spellings and the
auth call declares the expected origin via the plugin's `debugOrigin` — so the
plain `--web-port 8080` command works. Passing `--web-hostname 127.0.0.1` as
well makes the origins identical and removes the bridge entirely.

---

## 2. Development Mode — the February 2026 changes

This is the part most online guidance gets wrong. Sources:
[the announcement](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security),
[the migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide),
and [Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

| | Before | Now |
| --- | --- | --- |
| Users per app | 25 | **5** |
| Owner needs Premium | No | **Yes** |
| Client IDs per account | 1 | 25 (raised back in July 2026) |
| Endpoint set | Full | Reduced — see below |

**Premium requirement.** From the migration guide:

> "All Development Mode apps require the app owner to have an active Spotify
> Premium subscription. If the owner's Premium subscription lapses, the app
> will stop working. It will resume functioning once the owner resubscribes."

This applied to *existing* apps from 9 March 2026 and is **not** grandfathered.
It produces the same `403`-on-everything symptom as a missing allowlist entry,
which is why AURIX's access-denied screen lists both.

**Grandfathering, where it applies.** Extra Client IDs and existing user lists
above five are retained: "These limits only restrict what you can create or add
going forward."

**Extended Quota Mode still exists but is effectively closed to individuals** —
since 15 May 2025 Spotify accepts applications only from organisations, and the
published bar includes a minimum of 250,000 monthly active users. Assume you
will stay in Development Mode.

**Endpoint restrictions were partly postponed.** An update appended to the
February 2026 announcement reads:

> "After some review and feedback from the community, we have decided to
> postpone endpoint access changes for existing integrations. The Spotify
> Premium requirement, the authorized user cap and one Client ID per developer
> limit will take effect as planned for existing Development Mode integrations."

No new date had been announced as of August 2026. So the user cap and Premium
requirement are live; the endpoint removals below may or may not apply to your
app depending on when it was created.

---

## 3. What a Development Mode app cannot call

AURIX is built to degrade rather than break when these return `403`/`404` — see
[`API_LIMITATIONS.md`](API_LIMITATIONS.md) and the `Restricted` class in
`lib/core/constants/spotify_endpoints.dart`.

**Unavailable to apps created on or after 27 November 2024**
([announcement](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api)):
Related Artists · Recommendations · Audio Features · Audio Analysis · Featured
Playlists · Category Playlists · 30-second `preview_url` in multi-get responses
· algorithmic and Spotify-owned editorial playlists.

**Additionally removed for Development Mode in February 2026**
([changelog](https://developer.spotify.com/documentation/web-api/references/changes/february-2026)):
`/browse/new-releases` · `/browse/categories` · `/artists/{id}/top-tracks` ·
multi-ID batch gets · `/users/{id}` and `/users/{id}/playlists` · `/markets` ·
search `limit` capped at 10.

**Fields removed from `GET /me`:** `country`, `email`, `explicit_content`,
`followers`, `product`.

That last line matters to this app in three places, all of which already
degrade safely:

| Field | Used for | Behaviour when absent |
| --- | --- | --- |
| `country` | the `market` parameter | falls back to `from_token` |
| `product` | gating Spotify Connect controls | treated as non-Premium |
| `explicit_content` | the explicit-content policy | policy reports `unknown`, local preference applies |

---

## 4. Access denied — reading the failure

A `403` on `GET /me` is diagnostic: that endpoint needs no scope and works for
any valid token, so a refusal is Spotify rejecting the *application* on behalf
of the *user*. AURIX routes it to `AccessDeniedScreen` rather than showing an
empty Home.

The documented behaviour, from Quota modes:

> "Users may be able to log into a development mode app without having been
> allowlisted by the developer. However, API requests with an access token
> associated to that user and app will receive a `403 status code error`."

The status code is documented; **the exact response body is not**. The commonly
cited `{"error":{"status":403,"message":"User not registered in the Developer
Dashboard"}}` appears only in community threads. AURIX therefore matches on that
message when it is present but never depends on it — an unrecognised 403 body
falls through to `AccessDenialCause.unspecified` and the screen lists causes
rather than asserting one.

---

## 5. Checklist

- [ ] App created; **Client ID** copied into `.env`
- [ ] Redirect URI `aurix://auth-callback` registered (mobile)
- [ ] Redirect URI `http://127.0.0.1:8080/auth.html` registered (web, if used)
- [ ] Both registered on the **same** app — the one whose Client ID is in `.env`
- [ ] Web run with `--web-port 8080` so the served port matches the pinned URI
- [ ] **Web API** ticked under "Which API/SDKs are you planning to use?"
- [ ] Every test account added under **User Management** (max 5)
- [ ] The **owner** account has active Spotify Premium
- [ ] No client secret anywhere in the repo

---

## Unverified

Kept explicit so nobody treats these as settled:

* The exact JSON body of the allowlist `403` (status code is documented; the
  message string is not).
* The full list of "Which API/SDKs are you planning to use?" options — only
  that the question exists and that **Web API** is the one AURIX needs.
* An official step-by-step for the User Management tab; the 5-user cap is
  documented but the UI flow is described only in community threads.
* Published numeric rate limits — Spotify documents a "rolling 30 second
  window" and a `Retry-After` header, but no figures.
* The new timeline for the postponed endpoint-access changes.
