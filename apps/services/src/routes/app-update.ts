/**
 * App Update Routes
 * 
 * API endpoints for the auto-update system.
 */

import { OpenAPIHono, createRoute } from '@hono/zod-openapi';
import { 
  UpdateRequestSchema,
  UpdateManifestResponseSchema,
} from '../schemas/app-update';
import { R2UpdateManifestProvider } from '../services/app-update';
import type { UpdateManifest } from '../services/app-update';

// Type definition for Bindings (no KV; manifest = released file latest-mac.yml only)
type Bindings = {
  R2_ENDPOINT: string;
  R2_BUCKET_NAME: string;
  R2_PUBLIC_URL?: string;
};

/**
 * Create app update router
 */
export function createAppUpdateRouter() {
  const app = new OpenAPIHono<{ Bindings: Bindings }>();
  
  // Get update manifest endpoint
  const getUpdateManifestRoute = createRoute({
    method: 'get',
    path: '/manifest',
    tags: ['App Update'],
    summary: 'Get update manifest',
    description: 'Check for available app updates and get download manifest',
    request: {
      query: UpdateRequestSchema,
    },
    responses: {
      200: {
        description: 'Update manifest (YAML format)',
        content: {
          'text/yaml': {
            schema: UpdateManifestResponseSchema,
          },
        },
      },
      204: {
        description: 'No update available',
      },
      500: {
        description: 'Internal server error',
      },
    },
  });
  
  app.openapi(getUpdateManifestRoute, async (c) => {
    const { channel, platform } = c.req.valid('query');
    
    try {
      const manifestProvider = new R2UpdateManifestProvider(
        c.env.R2_ENDPOINT,
        c.env.R2_BUCKET_NAME,
        c.env.R2_PUBLIC_URL
      );
      // Read released manifest only (latest-mac.yml); pre is not used here
      const manifest = await manifestProvider.getManifest(channel, platform);
      
      if (!manifest) {
        return c.body(null, 204);
      }

      // Convert manifest to YAML format (URLs stay as R2; download is proxied by rule when needed)
      const yaml = manifestToYaml(manifest);
      return c.text(yaml, 200, {
        'Content-Type': 'text/yaml',
        'Cache-Control': 'no-cache',
      });
    } catch (error: any) {
      console.error('[AppUpdateRoute] Error handling update request:', error);
      return c.json({
        success: false,
        error: error.message || 'Failed to check for updates',
      }, 500);
    }
  });

  // Download proxy: build R2 URL by rule (base + channel + filename), stream through
  // A) By channel + filename (desktop or direct link)
  app.get('/download/:channel/:filename', async (c) => {
    const channel = c.req.param('channel');
    const filename = c.req.param('filename');
    if (!channel || !filename || !/^[a-zA-Z0-9._-]+$/.test(filename)) {
      return c.json({ error: 'Invalid channel or filename' }, 400);
    }
    const r2Base = getR2BaseUrl(c.env);
    const fileUrl = `${r2Base}/${channel}/${filename}`;
    return streamFromR2(c, fileUrl, filename);
  });

  // B) Latest for channel+platform: read YAML from R2 to get path, then stream
  // format=dmg (default) serves DMG for manual download; format=zip serves ZIP
  app.get('/download', async (c) => {
    const channel = (c.req.query('channel') || 'production') as string;
    const platform = (c.req.query('platform') || 'darwin') as string;
    const format = (c.req.query('format') || 'dmg') as string;
    if (!['beta', 'production'].includes(channel)) {
      return c.json({ error: 'Invalid channel' }, 400);
    }
    const r2Base = getR2BaseUrl(c.env);
    const platformName = platform === 'darwin' ? 'mac' : platform;
    const yamlUrl = `${r2Base}/${channel}/latest-${platformName}.yml`;
    const zipPath = await fetchPathFromYaml(yamlUrl);
    if (!zipPath) {
      return c.json({ error: 'Latest manifest not found' }, 404);
    }
    const filePath = format === 'dmg' ? zipPathToDmg(zipPath) : zipPath;
    const fileUrl = `${r2Base}/${channel}/${filePath}`;
    return streamFromR2(c, fileUrl, filePath);
  });

  // ── electron-updater feed proxy ────────────────────────────────────────
  // Feed URL = {apiBase}/api/app/updates/feed/{channel}
  // electron-updater fetches {feedUrl}/latest-mac.yml → YAML proxy
  // electron-updater downloads {feedUrl}/{filename}  → file proxy
  //
  // The YAML is returned as-is from R2 (relative URLs).
  // electron-updater resolves relative paths against the feed URL,
  // so file downloads also hit this backend → we proxy to R2.
  // This is the control plane hook: future grayscale / user gating goes here.

  app.get('/feed/:channel/latest-mac.yml', async (c) => {
    const channel = c.req.param('channel');
    if (channel !== 'beta' && channel !== 'production') {
      return c.json({ error: 'Invalid channel' }, 400);
    }

    // TODO: grayscale — check user identity / KV config to decide whether to serve update

    const r2Base = getR2BaseUrl(c.env);
    const yamlUrl = `${r2Base}/${channel}/latest-mac.yml`;

    try {
      const res = await fetch(yamlUrl);
      if (!res.ok) {
        // No published manifest → electron-updater sees 404 → "no update available"
        return new Response(null, { status: 404 });
      }
      const body = await res.text();
      return c.text(body, 200, {
        'Content-Type': 'text/yaml',
        'Cache-Control': 'no-cache, no-store',
      });
    } catch (error) {
      console.error('[Feed] Failed to proxy YAML:', error);
      return new Response(null, { status: 502 });
    }
  });

  app.get('/feed/:channel/:filename', async (c) => {
    const channel = c.req.param('channel');
    const filename = c.req.param('filename');
    if (!channel || !filename || !/^[a-zA-Z0-9._-]+$/.test(filename)) {
      return c.json({ error: 'Invalid channel or filename' }, 400);
    }
    // TODO: future — signed R2 URLs go here
    const r2Base = getR2BaseUrl(c.env);
    const fileUrl = `${r2Base}/${channel}/${filename}`;
    return streamFromR2(c, fileUrl, filename);
  });

  return app;
}

function getR2BaseUrl(env: Bindings): string {
  return env.R2_PUBLIC_URL?.replace(/\/$/, '') ?? `${env.R2_ENDPOINT}/${env.R2_BUCKET_NAME}`;
}

// electron-builder naming: ZIP = "Xisper-0.1.0-arm64-mac.zip", DMG = "Xisper-0.1.0-arm64.dmg"
function zipPathToDmg(zipPath: string): string {
  return zipPath.replace(/-mac\.zip$/, '.dmg');
}

async function fetchPathFromYaml(yamlUrl: string): Promise<string | null> {
  const res = await fetch(yamlUrl);
  if (!res.ok) return null;
  const text = await res.text();
  const match = text.match(/^\s*path:\s*["']?([^\s"'\n]+)/m);
  return match ? match[1].trim() : null;
}

async function streamFromR2(
  c: { env: Bindings },
  fileUrl: string,
  filename: string
): Promise<Response> {
  const res = await fetch(fileUrl);
  if (!res.ok) {
    return new Response(null, { status: res.status === 404 ? 404 : 502 });
  }
  const contentType = res.headers.get('Content-Type') || 'application/octet-stream';
  const headers = new Headers({
    'Content-Type': contentType,
    'Content-Disposition': `attachment; filename="${filename}"`,
  });
  if (res.headers.has('Content-Length')) {
    headers.set('Content-Length', res.headers.get('Content-Length')!);
  }
  return new Response(res.body, { status: 200, headers });
}

/**
 * Convert UpdateManifest to YAML format
 * 
 * Converts the manifest object to electron-updater compatible YAML format.
 */
function manifestToYaml(manifest: UpdateManifest): string {
  const lines: string[] = [];
  
  // Version
  lines.push(`version: ${manifest.version}`);
  
  // Files array
  if (manifest.files && manifest.files.length > 0) {
    lines.push('files:');
    for (const file of manifest.files) {
      lines.push(`  - url: ${file.url}`);
      lines.push(`    sha512: ${file.sha512}`);
      lines.push(`    size: ${file.size}`);
    }
  }
  
  // Path
  lines.push(`path: ${manifest.path}`);
  
  // SHA512
  lines.push(`sha512: ${manifest.sha512}`);
  
  // Release date
  if (manifest.releaseDate) {
    lines.push(`releaseDate: '${manifest.releaseDate}'`);
  }
  
  // Release name
  if (manifest.releaseName) {
    lines.push(`releaseName: ${manifest.releaseName}`);
  }
  
  // Release notes
  if (manifest.releaseNotes) {
    const notes = manifest.releaseNotes.replace(/\n/g, '\n  ');
    lines.push(`releaseNotes: |`);
    lines.push(`  ${notes}`);
  }
  
  // Mandatory flag (custom field)
  if (manifest.mandatory !== undefined) {
    lines.push(`mandatory: ${manifest.mandatory}`);
  }
  
  return lines.join('\n');
}

export default createAppUpdateRouter;
