import path from 'node:path';
import { fileURLToPath } from 'node:url';

import compression from 'compression';
import cors from 'cors';
import express from 'express';
import helmet from 'helmet';

import { env } from './config/env.js';
import { ping } from './db/mongo.js';
import { errorHandler, notFoundHandler } from './middleware/error.js';

import adminRoutes from './routes/admin.routes.js';
import assetsRoutes from './routes/assets.routes.js';
import authRoutes from './routes/auth.routes.js';
import catalogRoutes from './routes/catalog.routes.js';
import libraryRoutes from './routes/library.routes.js';
import playlistsRoutes from './routes/playlists.routes.js';
import profileRoutes from './routes/profile.routes.js';
import sharedPlaylistsRoutes from './routes/sharedPlaylists.routes.js';
import themeRoutes from './routes/theme.routes.js';

const here = path.dirname(fileURLToPath(import.meta.url));

/**
 * The Express application.
 *
 * Kept separate from `index.js` so tests can mount the whole API against a
 * throwaway database without binding a port — the same separation `app.dart`
 * has from `main.dart` on the Flutter side, and for the same reason.
 */
export function createApp() {
  const app = express();

  // Behind a reverse proxy on every real deployment. Without this the rate
  // limiters key on the proxy's address and limit the whole world as one
  // client — which turns a per-IP limit into a global outage under load.
  app.set('trust proxy', 1);
  app.disable('x-powered-by');

  app.use(
    helmet({
      // The admin panel is served from this origin and is the only HTML here.
      // Its script and styles are inline, so the policy names them explicitly
      // rather than opening `unsafe-inline` to everything.
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          scriptSrc: ["'self'", "'unsafe-inline'"],
          styleSrc: ["'self'", "'unsafe-inline'"],
          imgSrc: ["'self'", 'data:', 'blob:'],
          fontSrc: ["'self'", 'data:'],
          connectSrc: ["'self'"],
          objectSrc: ["'none'"],
          frameAncestors: ["'none'"],
        },
      },
      // Assets are served cross-origin to the Flutter web build, which is a
      // different origin in every deployment that has one.
      crossOriginResourcePolicy: { policy: 'cross-origin' },
    }),
  );

  app.use(
    cors({
      // An empty allow-list reflects the request origin, which is right for
      // local development against a Flutter web build on a random port and
      // wrong in production — `index.js` warns at boot when that combination
      // is live.
      origin: env.corsOrigins.length > 0 ? env.corsOrigins : true,
      credentials: false,
      maxAge: 86400,
    }),
  );

  app.use(compression());

  // 1MB covers a 2,000-track playlist write with room to spare, and is small
  // enough that an unbounded body cannot exhaust memory. File uploads do not
  // pass through here — multer handles those with its own, larger caps.
  app.use(express.json({ limit: '1mb' }));

  app.get('/health', async (_req, res) => {
    const db = await ping();
    res.status(db ? 200 : 503).json({
      ok: db,
      service: 'aurix-api',
      db: db ? 'up' : 'down',
      uptime: Math.round(process.uptime()),
    });
  });

  const api = express.Router();
  api.use('/auth', authRoutes);
  api.use('/profile', profileRoutes);
  api.use('/library', libraryRoutes);
  api.use('/playlists', playlistsRoutes);
  api.use('/shared-playlists', sharedPlaylistsRoutes);
  api.use('/catalog', catalogRoutes);
  api.use('/theme', themeRoutes);
  api.use('/assets', assetsRoutes);
  api.use('/admin', adminRoutes);

  // Versioned from the start. The Dart client pins `/api/v1`, so a breaking
  // change ships as `/api/v2` alongside it rather than as a release that
  // strands every install that has not updated.
  app.use('/api/v1', api);

  // The web admin panel. Same origin as the API it calls, so it needs no CORS
  // grant and no separate deployment.
  app.use('/admin', express.static(path.join(here, '../public/admin'), { index: 'index.html' }));
  app.get('/', (_req, res) => res.redirect('/admin/'));

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
