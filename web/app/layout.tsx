import type { Metadata, Viewport } from 'next';

import './globals.css';

export const metadata: Metadata = {
  title: {
    default: 'AURIX',
    template: '%s · AURIX',
  },
  description: 'AURIX — API and administration.',
  // The portal is an internal tool behind a sign-in. Indexing it would only
  // ever surface a login page to a search engine.
  robots: { index: false, follow: false },
};

export const viewport: Viewport = {
  themeColor: '#000000',
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className="min-h-dvh antialiased">{children}</body>
    </html>
  );
}
