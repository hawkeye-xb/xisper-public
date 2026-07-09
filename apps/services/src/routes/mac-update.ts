/**
 * Mac Native Update Routes (Sparkle 2)
 *
 * Serves appcast.xml for the native Swift app via native R2 binding.
 * Completely separate from the Electron update routes at /api/app/updates.
 *
 * GET  /api/v1/app/mac/updates/feed/:channel
 *   → Reads mac-{channel}/appcast.xml from RELEASES_R2 bucket.
 *   → Control plane hook: grayscale / forced-update logic goes here.
 *
 * GET  /api/v1/app/mac/updates/download/:channel/:filename
 *   → Streams mac-{channel}/{filename} from RELEASES_R2 bucket.
 *
 * POST /api/v1/app/mac/updates/promote/:channel
 *   → Copies mac-{channel}/appcast-pre.xml → mac-{channel}/appcast.xml in R2.
 *   → Admin-only; requires x-admin-secret header.
 */

import { Hono } from 'hono';

type Bindings = {
  RELEASES_R2?: R2Bucket;
  MAC_UPDATE_PROMOTE_SECRET?: string;
  ENVIRONMENT?: string;
};

export function createMacUpdateRouter() {
  const app = new Hono<{ Bindings: Bindings }>();

  // ── Feed (Sparkle SUFeedURL) ─────────────────────────────────────────────
  // Sparkle requests: GET /api/v1/app/mac/updates/feed/{channel}
  // Returns the appcast.xml from R2 native binding.

  app.get('/feed/:channel', async (c) => {
    const channel = c.req.param('channel');
    if (channel !== 'beta' && channel !== 'production') {
      return c.json({ error: 'Invalid channel' }, 400);
    }

    const bucket = c.env.RELEASES_R2;
    if (!bucket) {
      console.error('[MacUpdate] RELEASES_R2 not configured');
      return new Response(null, { status: 502 });
    }

    try {
      const obj = await bucket.get(`mac-${channel}/appcast.xml`);
      if (!obj) {
        // No published appcast yet → Sparkle sees 204/empty → "no update available".
        return new Response(null, { status: 404 });
      }
      const body = await obj.text();
      return c.text(body, 200, {
        'Content-Type': 'application/xml; charset=utf-8',
        'Cache-Control': 'no-cache, no-store',
      });
    } catch (err) {
      console.error('[MacUpdate] Failed to read appcast.xml:', err);
      return new Response(null, { status: 502 });
    }
  });

  // ── Latest DMG redirect ─────────────────────────────────────────────────
  // Landing page / marketing links use this to always get the latest version.
  // Reads appcast.xml, extracts the enclosure URL, and 302-redirects.

  app.get('/download/:channel/latest', async (c) => {
    const channel = c.req.param('channel');
    if (channel !== 'beta' && channel !== 'production') {
      return c.json({ error: 'Invalid channel' }, 400);
    }

    const bucket = c.env.RELEASES_R2;
    if (!bucket) {
      return new Response(null, { status: 502 });
    }

    try {
      const obj = await bucket.get(`mac-${channel}/appcast.xml`);
      if (!obj) {
        return c.json({ error: 'No release available' }, 404);
      }
      const xml = await obj.text();
      // Extract enclosure url from appcast XML
      const match = xml.match(/enclosure\s+url="([^"]+)"/);
      if (!match) {
        return c.json({ error: 'No download URL in appcast' }, 500);
      }
      return c.redirect(match[1], 302);
    } catch (err) {
      console.error('[MacUpdate] Latest redirect failed:', err);
      return new Response(null, { status: 502 });
    }
  });

  // ── DMG download proxy ───────────────────────────────────────────────────
  // Sparkle resolves <enclosure url="…"> relative to the feed; if the URL
  // points back to this backend we stream from R2 here.

  app.get('/download/:channel/:filename', async (c) => {
    const channel = c.req.param('channel');
    const filename = c.req.param('filename');
    if (!channel || !filename || !/^[a-zA-Z0-9._-]+$/.test(filename)) {
      return c.json({ error: 'Invalid channel or filename' }, 400);
    }

    const bucket = c.env.RELEASES_R2;
    if (!bucket) {
      return new Response(null, { status: 502 });
    }

    const obj = await bucket.get(`mac-${channel}/${filename}`);
    if (!obj) {
      return new Response(null, { status: 404 });
    }

    const headers = new Headers({
      'Content-Type': obj.httpMetadata?.contentType ?? 'application/octet-stream',
      'Content-Disposition': `attachment; filename="${filename}"`,
    });
    if (obj.size) {
      headers.set('Content-Length', String(obj.size));
    }
    return new Response(obj.body, { status: 200, headers });
  });

  // ── Promote (Admin) ──────────────────────────────────────────────────────
  // Atomically promotes a pre-release appcast to the live feed.
  // Used by CI after QA sign-off, mirroring the Electron promote flow.

  app.post('/promote/:channel', async (c) => {
    const channel = c.req.param('channel');
    if (channel !== 'beta' && channel !== 'production') {
      return c.json({ error: 'Invalid channel' }, 400);
    }

    // Beta worker can only promote beta
    const env = c.env.ENVIRONMENT || 'development';
    if (env === 'beta' && channel === 'production') {
      return c.json({ error: 'Beta admin cannot promote to production' }, 403);
    }

    // Lightweight admin auth: shared secret in header.
    const secret = c.req.header('x-mac-update-secret');
    if (!secret || secret !== c.env.MAC_UPDATE_PROMOTE_SECRET) {
      return c.json({ error: 'Unauthorized' }, 401);
    }

    const bucket = c.env.RELEASES_R2;
    if (!bucket) {
      return c.json({ error: 'RELEASES_R2 not configured' }, 500);
    }

    try {
      const preObj = await bucket.get(`mac-${channel}/appcast-pre.xml`);
      if (!preObj) {
        return c.json({ error: 'Pre-release appcast not found. Upload a build first.' }, 404);
      }

      const preXml = await preObj.text();
      await bucket.put(`mac-${channel}/appcast.xml`, preXml);

      console.log(`[MacUpdate] Promoted mac-${channel}/appcast-pre.xml → appcast.xml`);
      return c.json({ ok: true, channel, promoted: new Date().toISOString() });
    } catch (err) {
      console.error('[MacUpdate] Promote failed:', err);
      return c.json({ error: 'Promote failed' }, 500);
    }
  });

  return app;
}

export default createMacUpdateRouter;
