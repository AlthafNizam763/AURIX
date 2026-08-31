import type { NextConfig } from 'next';

/**
 * Next.js configuration for the AURIX web application.
 *
 * ## What this file replaces
 *
 * `helmet()` in `server/src/app.js`. Express applied those headers as
 * middleware; Next applies them from configuration, and the *policy* is meant
 * to be the same one — with one deliberate widening, noted below.
 */

const isProduction = process.env.NODE_ENV === 'production';

/**
 * The Content-Security-Policy for the HTML this file still owns.
 *
 * ## Which pages that is, and why the portal is not among them
 *
 * `/`, which only redirects, and the 404. Both are prerendered at build time,
 * which is exactly why they are served a *static* policy: there is no request
 * during their render into which a per-request nonce could be threaded.
 *
 * Everything under `/admin` is excluded and gets its policy from
 * `middleware.ts` instead, with a nonce. That is not a stylistic preference —
 * it is the fix for a bug this header caused. `script-src 'self'` was written
 * on the belief that the React portal has no inline scripts, and the App
 * Router does: it streams the RSC payload to the browser as inline
 * `self.__next_f.push(...)` elements. Blocking them left the portal rendering
 * perfectly on the server and then replacing itself with an error screen in the
 * browser. See the long note on `portalCsp` in `middleware.ts`.
 *
 * These two pages keep `'unsafe-inline'` for scripts for the same reason: they
 * are App Router pages and they carry the same inline payload. Neither has a
 * session, a form or a cookie to steal, so the allowance costs little — and a
 * nonce is not available to a prerendered page at any price.
 *
 * Styles keep `'unsafe-inline'` because Next and Tailwind both inject inline
 * `<style>` elements during hydration. An injected stylesheet can deface a
 * page, where an injected script can read a session.
 *
 * `'unsafe-eval'` is allowed in development only — the dev-mode React refresh
 * transform requires it. It is never sent in production.
 */
const contentSecurityPolicy = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline'${isProduction ? '' : " 'unsafe-eval'"}`,
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data:",
  "connect-src 'self'",
  "object-src 'none'",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
].join('; ');

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,

  // The Mongo driver is a native Node consumer and cannot be bundled for the
  // Edge runtime. Every route handler additionally declares
  // `export const runtime = 'nodejs'`; this keeps the driver out of the
  // server bundle so it is required at runtime instead.
  serverExternalPackages: ['mongodb', 'bcryptjs', 'nodemailer'],

  async headers() {
    return [
      {
        // Everything. The API needs the transport and sniffing protections as
        // much as the portal does.
        source: '/:path*',
        headers: [
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'X-Frame-Options', value: 'DENY' },
          { key: 'Referrer-Policy', value: 'no-referrer' },
          { key: 'X-DNS-Prefetch-Control', value: 'off' },
          {
            key: 'Permissions-Policy',
            value: 'camera=(), microphone=(), geolocation=(), interest-cohort=()',
          },
          // HSTS in production only: sending it from a local http:// dev server
          // would pin the browser to https for localhost and break every other
          // project on that port.
          ...(isProduction
            ? [
                {
                  key: 'Strict-Transport-Security',
                  value: 'max-age=63072000; includeSubDomains; preload',
                },
              ]
            : []),
        ],
      },
      {
        // The CSP applies to the HTML surface only. Sending it on a JSON body
        // is noise — there are no scripts in one to restrict. `health` is
        // excluded alongside `api` because it is JSON too, despite sitting
        // outside the versioned prefix.
        //
        // `admin` is excluded because `middleware.ts` sends it a nonced policy
        // of its own. Two `Content-Security-Policy` headers on one response are
        // not merged by a browser — every one of them is enforced, so the
        // stricter wins — and this one has no nonce in it. Leaving the portal
        // matched here would silently reinstate the bug the nonce exists to fix.
        source: '/((?!api/|health|admin$|admin/).*)',
        headers: [{ key: 'Content-Security-Policy', value: contentSecurityPolicy }],
      },
      {
        // Brand assets are served cross-origin to the Flutter web build, which
        // is a different origin in every deployment that has one. Mirrors
        // `crossOriginResourcePolicy: 'cross-origin'` from the Express app.
        source: '/api/v1/assets/:path*',
        headers: [{ key: 'Cross-Origin-Resource-Policy', value: 'cross-origin' }],
      },
    ];
  },
};

export default nextConfig;
