import { OpenAPIHono } from '@hono/zod-openapi';
import { HTTPException } from 'hono/http-exception';
import { getCookie, setCookie, deleteCookie } from 'hono/cookie';
import { authMiddleware, decodeJWT as sharedDecodeJWT, type LogtoJWTPayload } from '../middlewares/auth';

type Bindings = {
  AI_KV: KVNamespace;
  DB: D1Database;
  LOGTO_ENDPOINT: string;
  LOGTO_APP_ID?: string;
  LOGTO_APP_SECRET?: string;
  SERVICE_BASE_URL?: string;
};

const authRouter = new OpenAPIHono<{ Bindings: Bindings }>();

/**
 * Helper: Generate random hex string
 */
function generateRandomHex(bytes: number): string {
  const array = new Uint8Array(bytes);
  crypto.getRandomValues(array);
  return Array.from(array).map(b => b.toString(16).padStart(2, '0')).join('');
}

// Use shared decodeJWT from auth middleware
const decodeJWT = sharedDecodeJWT;

/**
 * @deprecated Clients now use direct Logto PKCE flow. Kept for backward compatibility
 * with older app versions. Remove once all clients have updated.
 *
 * GET /auth/desktop
 * Desktop authorization page - initiates OAuth flow
 */
authRouter.get('/desktop', async (c) => {
  const challenge = c.req.query('challenge');
  const state = c.req.query('state');
  const redirect_uri = c.req.query('redirect_uri');

  // Validate parameters
  if (!challenge || challenge.length < 43 || challenge.length > 128) {
    throw new HTTPException(400, { message: 'Invalid challenge parameter' });
  }
  if (!state || state.length < 32) {
    throw new HTTPException(400, { message: 'Invalid state parameter' });
  }
  // Allow any xisper-prefixed scheme (xisper://, xisper-dev://, xisper-mac://, etc.)
  if (!redirect_uri || !redirect_uri.match(/^xisper[-a-z]*:\/\//)) {
    throw new HTTPException(400, { message: 'Invalid redirect_uri parameter' });
  }

  // Generate session ID
  const sessionId = crypto.randomUUID();

  // Store session data in KV
  await c.env.AI_KV.put(
    `auth:session:${sessionId}`,
    JSON.stringify({
      challenge,
      state,
      redirect_uri,
      timestamp: Date.now(),
    }),
    { expirationTtl: 600 } // 10 minutes
  );

  // Get service base URL
  const serviceBaseUrl = c.env.SERVICE_BASE_URL || 'http://localhost:8787';

  // Build Logto OAuth URL with PKCE
  // Use prompt=consent: if already logged in, just show consent; if not logged in, show login
  const authUrl = new URL(`${c.env.LOGTO_ENDPOINT}/oidc/auth`);
  authUrl.searchParams.set('client_id', c.env.LOGTO_APP_ID || '');
  authUrl.searchParams.set('redirect_uri', `${serviceBaseUrl}/auth/desktop/callback`);
  authUrl.searchParams.set('response_type', 'code');
  authUrl.searchParams.set('scope', 'openid profile email offline_access');
  authUrl.searchParams.set('state', sessionId);
  authUrl.searchParams.set('prompt', 'consent'); // If logged in: just authorize; if not: login first
  authUrl.searchParams.set('code_challenge', challenge); // PKCE challenge
  authUrl.searchParams.set('code_challenge_method', 'S256'); // SHA-256

  // Build URL with login prompt for switching accounts
  const switchAccountUrl = new URL(authUrl.toString());
  switchAccountUrl.searchParams.set('prompt', 'login'); // Force re-login to switch account

  // Return HTML page that redirects to auth
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sign in to Xisper</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif;
      background: #FAFAFA;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #333;
    }
    .container {
      text-align: center;
      padding: 48px 40px;
      background: white;
      border-radius: 16px;
      box-shadow: 0 2px 12px rgba(0, 0, 0, 0.08);
      max-width: 440px;
      border: 1px solid #EEEEEE;
    }
    .logo {
      font-size: 48px;
      margin-bottom: 24px;
      font-weight: 700;
      color: #F7A33F;
    }
    .spinner {
      width: 50px;
      height: 50px;
      border: 4px solid #EEEEEE;
      border-top-color: #F7A33F;
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
      margin: 0 auto 24px;
    }
    @keyframes spin {
      to { transform: rotate(360deg); }
    }
    h1 {
      font-size: 24px;
      font-weight: 600;
      margin-bottom: 12px;
      color: #212121;
    }
    p {
      font-size: 15px;
      color: #616161;
      line-height: 1.5;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">Xisper</div>
    <div class="spinner"></div>
    <h1>Redirecting to authorization...</h1>
    <p>Please wait a moment</p>
  </div>
  <script>
    // Redirect immediately to Logto
    // If user is already logged in, Logto will show consent screen (no re-login needed)
    // If user is not logged in, Logto will show login screen
    window.location.href = '${authUrl.toString()}';
  </script>
</body>
</html>`;

  return c.html(html);
});

/**
 * @deprecated Clients now use direct Logto PKCE flow. Kept for backward compatibility.
 *
 * GET /auth/desktop/callback
 * OAuth callback from Logto - passes authorization code to desktop app
 */
authRouter.get('/desktop/callback', async (c) => {
  const code = c.req.query('code');
  const state = c.req.query('state'); // This is our sessionId
  const error = c.req.query('error');

  // Handle OAuth errors
  if (error) {
    const errorDescription = c.req.query('error_description') || 'Authentication failed';
    throw new HTTPException(400, { message: `OAuth error: ${error} - ${errorDescription}` });
  }

  if (!code || !state) {
    throw new HTTPException(400, { message: 'Missing code or state parameter' });
  }

  // Retrieve session data from KV
  const sessionData = await c.env.AI_KV.get(`auth:session:${state}`);
  if (!sessionData) {
    throw new HTTPException(400, { message: 'Invalid or expired session' });
  }

  const session = JSON.parse(sessionData);
  const { state: originalState, redirect_uri } = session;

  // Delete session data (no longer needed)
  await c.env.AI_KV.delete(`auth:session:${state}`);

  // Get service base URL
  const serviceBaseUrl = c.env.SERVICE_BASE_URL || 'http://localhost:8787';

  // Build deep link to redirect back to desktop app
  // Pass the Logto authorization code directly to Desktop
  const deepLink = `${redirect_uri}?code=${code}&state=${originalState}`;

  // Check if this is from a consent screen (user was already logged in) or login screen
  // If from consent (already logged in), don't auto-open, let user decide
  // If from login (just logged in), auto-open after short delay
  // We can't reliably detect this from callback, so let's provide both options

  // Return HTML page with options to open app or switch account
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Authentication Successful</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif;
      background: #FAFAFA;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #333;
    }
    .container {
      text-align: center;
      padding: 48px 40px;
      background: white;
      border-radius: 16px;
      box-shadow: 0 2px 12px rgba(0, 0, 0, 0.08);
      max-width: 440px;
      border: 1px solid #EEEEEE;
    }
    .success-icon {
      width: 80px;
      height: 80px;
      margin: 0 auto 24px;
      background: rgba(50, 215, 75, 0.15);
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 48px;
      color: #32D74B;
      animation: scaleIn 0.3s ease-out;
    }
    @keyframes scaleIn {
      from {
        transform: scale(0);
        opacity: 0;
      }
      to {
        transform: scale(1);
        opacity: 1;
      }
    }
    h1 {
      font-size: 28px;
      font-weight: 600;
      margin-bottom: 12px;
      color: #212121;
    }
    p {
      font-size: 15px;
      color: #616161;
      margin-bottom: 32px;
      line-height: 1.5;
    }
    .actions {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    button {
      padding: 14px 36px;
      background: #F7A33F;
      color: white;
      border: none;
      border-radius: 10px;
      font-size: 16px;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.2s ease;
    }
    button:hover {
      background: #E68A1F;
      transform: translateY(-1px);
      box-shadow: 0 4px 12px rgba(247, 163, 63, 0.3);
    }
    button:active {
      transform: translateY(0);
    }
    button.secondary {
      background: transparent;
      color: #616161;
      border: 1px solid #E0E0E0;
    }
    button.secondary:hover {
      background: #FAFAFA;
      border-color: #BDBDBD;
      box-shadow: none;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="success-icon">✓</div>
    <h1>Authentication Successful!</h1>
    <p>You have successfully authorized Xisper</p>
    <div class="actions">
      <button onclick="openApp()">Open Xisper</button>
      <button class="secondary" onclick="switchAccount()">Switch Account</button>
    </div>
  </div>
  <script>
    const deepLink = '${deepLink}';
    const logtoEndpoint = '${c.env.LOGTO_ENDPOINT}';
    const serviceBaseUrl = '${serviceBaseUrl}';
    
    function openApp() {
      window.location.href = deepLink;
      // Show a message after attempting to open
      setTimeout(() => {
        document.querySelector('p').textContent = 'If the app did not open, please click the button again.';
      }, 2000);
    }
    
    function switchAccount() {
      // Update UI immediately
      document.querySelector('.success-icon').innerHTML = '↻';
      document.querySelector('h1').textContent = 'Switching Account...';
      document.querySelector('p').textContent = 'Logging out and preparing to use a different account';
      document.querySelector('.actions').style.display = 'none';
      
      // Construct logout URL with required parameters
      const logoutUrl = new URL(logtoEndpoint + '/oidc/session/end');
      logoutUrl.searchParams.set('client_id', '${c.env.LOGTO_APP_ID || ''}');
      logoutUrl.searchParams.set('post_logout_redirect_uri', serviceBaseUrl + '/auth/desktop/logout-complete');
      
      // Redirect to logout URL which will then redirect to logout-complete page
      window.location.href = logoutUrl.toString();
    }
  </script>
</body>
</html>`;

  return c.html(html);
});

/**
 * GET /auth/desktop/logout-complete
 * Logout completion page - tells user to go back to app and re-authorize
 */
authRouter.get('/desktop/logout-complete', async (c) => {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Logout Complete</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', sans-serif;
      background: #FAFAFA;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #333;
    }
    .container {
      text-align: center;
      padding: 48px 40px;
      background: white;
      border-radius: 16px;
      box-shadow: 0 2px 12px rgba(0, 0, 0, 0.08);
      max-width: 440px;
      border: 1px solid #EEEEEE;
    }
    .logo {
      font-size: 48px;
      margin-bottom: 24px;
      font-weight: 700;
      color: #F7A33F;
    }
    .info-icon {
      width: 80px;
      height: 80px;
      margin: 0 auto 24px;
      background: rgba(247, 163, 63, 0.15);
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 48px;
      color: #F7A33F;
    }
    h1 {
      font-size: 28px;
      font-weight: 600;
      margin-bottom: 16px;
      color: #212121;
    }
    p {
      font-size: 15px;
      color: #616161;
      line-height: 1.6;
      margin-bottom: 32px;
    }
    .highlight {
      font-weight: 600;
      color: #F7A33F;
    }
    button {
      padding: 14px 36px;
      background: #F7A33F;
      color: white;
      border: none;
      border-radius: 10px;
      font-size: 16px;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.2s ease;
    }
    button:hover {
      background: #E68A1F;
      transform: translateY(-1px);
      box-shadow: 0 4px 12px rgba(247, 163, 63, 0.3);
    }
    button:active {
      transform: translateY(0);
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">Xisper</div>
    <div class="info-icon">✓</div>
    <h1>Account Logged Out</h1>
    <p>You have been successfully logged out.<br><br>
    Please <span class="highlight">return to Xisper application</span> and click the authorization button again to log in with a different account.</p>
    <button onclick="closeWindow()">Close Window</button>
  </div>
  <script>
    function closeWindow() {
      // Try to close the window
      window.close();
      
      // If window doesn't close (not opened by script), show message
      setTimeout(() => {
        alert('Please close this window manually and return to Xisper application.');
      }, 500);
    }
    
    // Auto try to close after 3 seconds
    setTimeout(() => {
      window.close();
    }, 3000);
  </script>
</body>
</html>`;

  return c.html(html);
});

/**
 * POST /api/v1/auth/verify
 * Verify JWT token (for API requests)
 */
authRouter.post('/api/v1/auth/verify', async (c) => {
  const body = await c.req.json();
  const { token } = body;

  if (!token) {
    throw new HTTPException(400, { message: 'Missing token parameter' });
  }

  try {
    // Decode token (in production, should verify signature)
    const payload = decodeJWT(token);
    
    // Check expiry
    if (payload.exp && payload.exp * 1000 < Date.now()) {
      throw new HTTPException(401, { message: 'Token expired' });
    }

    return c.json({
      valid: true,
      userId: payload.sub,
      email: payload.email,
      expiresAt: payload.exp * 1000,
    });
  } catch (error) {
    if (error instanceof HTTPException) {
      throw error;
    }
    throw new HTTPException(401, { message: 'Invalid token' });
  }
});

/**
 * @deprecated Clients now exchange tokens directly with Logto via PKCE. Kept for backward compatibility.
 *
 * POST /auth/exchange-token
 * Exchange authorization code for token and set httpOnly cookie
 * Called by Electron renderer process after receiving code via deep link
 */
authRouter.post('/exchange-token', async (c) => {
  const { code, state, verifier } = await c.req.json();
  
  // Validate parameters
  if (!code || !state || !verifier) {
    throw new HTTPException(400, { message: 'Missing required parameters' });
  }
  
  // Get service base URL
  const serviceBaseUrl = c.env.SERVICE_BASE_URL || 'http://localhost:8787';
  
  try {
    // Exchange code for token with Logto OIDC
    const tokenResponse = await fetch(`${c.env.LOGTO_ENDPOINT}/oidc/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: `${serviceBaseUrl}/auth/desktop/callback`,
        client_id: c.env.LOGTO_APP_ID || '',
        code_verifier: verifier, // PKCE verifier from renderer
      }).toString(),
    });
    
    if (!tokenResponse.ok) {
      const errorText = await tokenResponse.text();
      throw new Error(`Token exchange failed: ${tokenResponse.status} ${errorText}`);
    }
    
    const tokenData = await tokenResponse.json() as Record<string, any>;
    const { id_token: idToken, refresh_token: refreshToken, expires_in } = tokenData;
    
    // Decode token to get user info (freshly issued, no need to verify signature)
    const payload = decodeJWT(idToken);
    
    // Return token in response body for localStorage storage
    // Note: Using Bearer Token authentication instead of cookies for Electron compatibility
    const maxAge = expires_in || 7 * 24 * 60 * 60; // Default 7 days
    
    return c.json({
      success: true,
      userId: payload.sub,
      email: payload.email,
      token: idToken,
      refreshToken: refreshToken || null,
      expiresIn: maxAge,
    });
  } catch (error) {
    throw new HTTPException(500, {
      message: error instanceof Error ? error.message : 'Token exchange failed',
    });
  }
});

/**
 * @deprecated Clients now refresh tokens directly with Logto via PKCE. Kept for backward compatibility.
 *
 * POST /auth/refresh
 * Exchange a refresh token for a new id_token + refresh_token pair.
 * Logto rotates refresh tokens on each use (configured in Logto dashboard).
 */
authRouter.post('/refresh', async (c) => {
  const { refreshToken } = await c.req.json();

  if (!refreshToken) {
    throw new HTTPException(400, { message: 'Missing refreshToken' });
  }

  try {
    const tokenResponse = await fetch(`${c.env.LOGTO_ENDPOINT}/oidc/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: refreshToken,
        client_id: c.env.LOGTO_APP_ID || '',
      }).toString(),
    });

    if (!tokenResponse.ok) {
      const errorText = await tokenResponse.text();
      console.error('[Auth] Refresh token exchange failed:', tokenResponse.status, errorText);
      throw new HTTPException(401, { message: 'Refresh token expired or invalid' });
    }

    const tokenData = await tokenResponse.json() as Record<string, any>;
    const {
      id_token: idToken,
      refresh_token: newRefreshToken,
      expires_in,
    } = tokenData;

    const payload = decodeJWT(idToken);

    return c.json({
      success: true,
      token: idToken,
      refreshToken: newRefreshToken || null,
      expiresIn: expires_in || 3600,
      userId: payload.sub,
      email: payload.email,
    });
  } catch (error) {
    if (error instanceof HTTPException) throw error;
    throw new HTTPException(500, {
      message: error instanceof Error ? error.message : 'Token refresh failed',
    });
  }
});

/**
 * POST /auth/logout
 * Logout endpoint (client handles token cleanup via localStorage)
 */
authRouter.post('/logout', async (c) => {
  // Client will clear localStorage token
  // This endpoint is optional for future server-side session management
  return c.json({ success: true });
});

/**
 * GET /auth/verify
 * Verify authentication status
 * Uses unified authMiddleware for token resolution + validation
 */
authRouter.get('/verify', authMiddleware, async (c: any) => {
  const payload = c.get('jwtPayload') as LogtoJWTPayload;
  return c.json({
    valid: true,
    userId: payload.sub,
    email: payload.email,
    expiresAt: payload.exp * 1000,
  });
});

/**
 * GET /auth/profile
 * Get current user profile (requires authentication)
 * Uses unified authMiddleware for token resolution + validation
 */
authRouter.get('/profile', authMiddleware, async (c: any) => {
  const payload = c.get('jwtPayload') as LogtoJWTPayload;
  return c.json({
    userId: payload.sub,
    email: payload.email || null,
    username: payload.username || null,
  });
});

/**
 * GET /auth/ws-token
 * Get token for WebSocket connection
 * Uses unified authMiddleware for token resolution + validation
 */
authRouter.get('/ws-token', authMiddleware, async (c: any) => {
  const payload = c.get('jwtPayload') as LogtoJWTPayload;
  return c.json({
    userId: payload.sub,
    token: c.req.header('Authorization')?.substring(7) || c.req.query('token') || '',
  });
});

export default authRouter;
