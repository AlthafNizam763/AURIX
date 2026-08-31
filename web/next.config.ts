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
 * The Content-Security-Policy for the admin portal.
 *
 * ## Why `'unsafe-inline'` on styles, and why not on scripts
 *
 * The Express policy allowed `'unsafe-inline'` for both, because the old admin
 * panel was one HTML file with an inline `<script>` and an inline `<style>`.
 * The React portal has neither: its JavaScript is served as files Next emits,
 * so scripts do not need it and are not granted it.
 *
 * Styles still are. Next and Tailwind both inject inline `<style>` elements
 * during hydration, and there is no nonce plumbing available from a static
 * header. This is the one place the new policy is weaker than the old one, and
 * it is weaker in the direction that matters least: an injected stylesheet can
 * deface a page, where an injected script can read a session.
 *
 * `'unsafe-eval'` is allowed in development only — the dev-mode React refresh
 * transform requires it. It is never sent in production.
 */
const contentSecurityPolicy = [
  "default-src 'self'",
  `script-src 'self'${isProduction ? '' : " 'unsafe-eval'"}`,
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
        source: '/((?!api/|health).*)',
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
