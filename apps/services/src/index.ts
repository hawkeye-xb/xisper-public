import { OpenAPIHono, createRoute } from '@hono/zod-openapi';
import { cors } from 'hono/cors';
import { logger } from 'hono/logger';
import { authMiddleware } from './middlewares/auth';
import { apiReference } from '@scalar/hono-api-reference';
import { z } from 'zod';

// Import routes
import authRouter from './routes/auth';
import adminRouter, { IDENTITIES_INDEX_KEY, IDENTITY_PREFIX, CORRECTION_PACKS_INDEX_KEY, CORRECTION_PACK_PREFIX } from './routes/admin';
import type { Identity, IdentityIndex, CorrectionPack, CorrectionPackIndex } from './routes/admin';
import adminAuthRouter from './routes/admin-auth';
import { handleASRWebSocket } from './routes/asr-proxy';
import createAppUpdateRouter from './routes/app-update';
import createMacUpdateRouter from './routes/mac-update';
import hotwordsRouter from './routes/hotwords';
import paymentRouter from './routes/payment';
import { resolveUserTier, resolveUserTierWithInfo } from './utils/subscription';
import { runSubscriptionAudit } from './cron/subscription-audit';

// Import schemas
import { HealthCheckResponseSchema, SystemInfoResponseSchema } from './schemas/health';
import { DEPLOY_INFO } from './generated/deploy-info';
import { 
  CreateUserRequestSchema, 
  CreateUserResponseSchema, 
  ListUsersResponseSchema,
  UserErrorResponseSchema 
} from './schemas/users';
import {
  CreateTaskRequestSchema,
  CreateTaskResponseSchema,
  ListTasksResponseSchema,
  TaskErrorResponseSchema,
  QuotaExceededResponseSchema
} from './schemas/tasks';
import {
  QuotaResponseSchema,
  QuotaIncrementResponseSchema,
  QuotaHistoryResponseSchema,
  QuotaErrorResponseSchema
} from './schemas/quota';
import {
  LLMPostprocessRequestSchema,
  LLMPostprocessSuccessResponseSchema,
  LLMPostprocessErrorResponseSchema,
  ChatCompletionRequestSchema,
} from './schemas/llm';
import {
  QuotaStatusResponseSchema,
  QuotaStatusErrorResponseSchema,
} from './schemas/rate-limit';
import { checkLLMQuota, getQuotaStatus, fetchCustomLimits } from './utils/rate-limiter';
import { normalizeTier } from './config/rate-limits';

// JWT verification is now handled by shared authMiddleware from middlewares/auth.ts

// Type for Cloudflare Rate Limiting binding (Wrangler 4.36+)
interface RateLimitBinding {
  limit: (opts: { key: string }) => Promise<{ success: boolean }>;
}

// Type definitions for Cloudflare Workers environment
type Bindings = {
  AI_KV: KVNamespace;
  DB: D1Database;
  FILES?: R2Bucket;
  AI_WORKER: Fetcher;
  LOGTO_ENDPOINT: string;
  LOGTO_APP_ID?: string;
  LOGTO_APP_SECRET?: string;
  SERVICE_BASE_URL?: string;
  ALLOWED_ORIGINS?: string;
  OPENAI_API_KEY?: string;
  DEEPSEEK_API_KEY?: string;
  CREEM_API_KEY: string;
  PAYMENT_WEBHOOK_SECRET?: string;
  ENVIRONMENT: string;
  ALLOWED_ORIGINS?: string;
  DOUBAO_APP_ID?: string;
  DOUBAO_ACCESS_TOKEN?: string;
  DOUBAO_RESOURCE_ID?: string;
  DOUBAO_CLUSTER?: string;
  ALIBABA_API_KEY?: string;
  ALIBABA_VOCABULARY_ID?: string;
  APP_UPDATE_CONFIG: KVNamespace;
  R2_ENDPOINT: string;
  R2_BUCKET_NAME: string;
  R2_PUBLIC_URL?: string;
  RELEASES_R2?: R2Bucket;
  MAC_UPDATE_PROMOTE_SECRET?: string;
  /** IP-based rate limiter (per CF location), 120 req/60s when configured */
  IP_RATE_LIMITER?: RateLimitBinding;
};

const app = new OpenAPIHono<{ Bindings: Bindings }>();

// Global middlewares
app.use('*', logger());
app.use('*', async (c, next) => {
  const environment = c.env.ENVIRONMENT || 'development';
  const configuredOrigins = (c.env.ALLOWED_ORIGINS || '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);

  const corsMiddleware = cors({
    origin: (origin) => {
      if (!origin) return '';
      if (
        environment === 'development' &&
        /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)
      ) {
        return origin;
      }
      return configuredOrigins.includes(origin) ? origin : '';
    },
    credentials: true,
    allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowHeaders: ['Content-Type', 'Authorization', 'X-Admin-Setup-Secret'],
  });

  return corsMiddleware(c, next);
});

// Demo endpoints are development-only and still require a valid user token.
app.use('/api/v1/demo/*', async (c, next) => {
  if ((c.env.ENVIRONMENT || 'development') !== 'development') {
    return c.json({ error: 'Not Found' }, 404);
  }
  return authMiddleware(c, next);
});

// The status route previously decoded JWT payloads without verifying their signature.
app.use('/api/v1/rate-limit/status', authMiddleware);

// WebSocket handler (must be before other routes)
app.use('/api/v1/asr/proxy', async (c, next) => {
  const upgradeHeader = c.req.header('Upgrade');
  if (upgradeHeader === 'websocket') {
    return handleASRWebSocket(c);
  }
  await next();
});

// Redirect root to landing page in beta/production; hide docs in beta/production
app.use('*', async (c, next) => {
  const path = new URL(c.req.url).pathname;
  const env = c.env.ENVIRONMENT || 'development';
  if (path === '/' && (env === 'beta' || env === 'production')) {
    return c.redirect('https://xisper-landing.hawkeye-xb.com/', 302);
  }
  if ((path === '/docs' || path === '/openapi.json') && (env === 'beta' || env === 'production')) {
    return c.json({ error: 'Not Found' }, 404);
  }
  return next();
});

// ============================================
// OpenAPI Documentation (development only)
// ============================================

app.doc('/openapi.json', {
  openapi: '3.0.0',
  info: {
    version: '1.0.0',
    title: 'Xisper Services API',
    description: 'AI-powered backend services built on Cloudflare Workers with Logto authentication and DeepSeek integration',
  },
  servers: [
    {
      url: 'http://localhost:8787',
      description: 'Development server',
    },
    {
      url: 'https://xisper-dev.hawkeye-xb.com',
      description: 'Beta server',
    },
    {
      url: 'https://xisper.hawkeye-xb.com',
      description: 'Production server',
    },
  ],
  tags: [
    { name: 'Health', description: 'System health and status endpoints' },
    { name: 'Users', description: 'User management operations' },
    { name: 'Tasks', description: 'AI task creation and tracking' },
    { name: 'Quota', description: 'Quota and usage tracking' },
  ],
});

// Swagger UI with Scalar
app.get('/docs', apiReference({
  theme: 'purple',
  spec: {
    url: '/openapi.json',
  },
}));

// ============================================
// Root Endpoint
// ============================================

// Root endpoint - Return demo HTML page
app.get('/', (c) => {
  const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AI Services Demo</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .container {
      background: white;
      border-radius: 20px;
      box-shadow: 0 20px 60px rgba(0, 0, 0, 0.3);
      max-width: 600px;
      width: 100%;
      padding: 40px;
    }
    h1 { color: #333; margin-bottom: 10px; font-size: 28px; }
    .subtitle { color: #666; margin-bottom: 30px; font-size: 14px; }
    .status {
      padding: 15px;
      border-radius: 10px;
      margin-bottom: 20px;
      font-size: 14px;
    }
    .status.info { background: #e3f2fd; color: #1976d2; }
    .status.success { background: #e8f5e9; color: #388e3c; }
    .status.error { background: #ffebee; color: #c62828; }
    button {
      width: 100%;
      padding: 15px;
      border: none;
      border-radius: 10px;
      font-size: 16px;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.3s ease;
      margin-bottom: 10px;
    }
    button:hover {
      transform: translateY(-2px);
      box-shadow: 0 5px 15px rgba(0, 0, 0, 0.2);
    }
    button.primary {
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: white;
    }
    button.secondary { background: #f5f5f5; color: #333; }
    button:disabled {
      opacity: 0.5;
      cursor: not-allowed;
      transform: none;
    }
    .input-group { margin-bottom: 20px; }
    label {
      display: block;
      margin-bottom: 8px;
      color: #333;
      font-weight: 500;
      font-size: 14px;
    }
    textarea {
      width: 100%;
      padding: 12px;
      border: 2px solid #e0e0e0;
      border-radius: 10px;
      font-size: 14px;
      font-family: inherit;
      resize: vertical;
      min-height: 80px;
      transition: border-color 0.3s ease;
    }
    textarea:focus {
      outline: none;
      border-color: #667eea;
    }
    .result {
      background: #f9f9f9;
      padding: 20px;
      border-radius: 10px;
      margin-top: 20px;
      display: none;
    }
    .result.show { display: block; }
    .result h3 {
      color: #333;
      margin-bottom: 10px;
      font-size: 16px;
    }
    .result p {
      color: #666;
      line-height: 1.6;
      font-size: 14px;
    }
    .quota {
      display: flex;
      justify-content: space-between;
      margin-top: 15px;
      padding-top: 15px;
      border-top: 2px solid #e0e0e0;
    }
    .quota-item { text-align: center; }
    .quota-label {
      color: #999;
      font-size: 12px;
      text-transform: uppercase;
      margin-bottom: 5px;
    }
    .quota-value {
      color: #333;
      font-size: 20px;
      font-weight: 600;
    }
    .loading {
      text-align: center;
      padding: 20px;
      color: #666;
    }
    .spinner {
      display: inline-block;
      width: 20px;
      height: 20px;
      border: 3px solid rgba(102, 126, 234, 0.3);
      border-radius: 50%;
      border-top-color: #667eea;
      animation: spin 0.8s linear infinite;
    }
    .docs-link {
      display: inline-block;
      margin-top: 20px;
      padding: 10px 20px;
      background: #667eea;
      color: white;
      text-decoration: none;
      border-radius: 8px;
      font-size: 14px;
      transition: all 0.3s ease;
    }
    .docs-link:hover {
      background: #764ba2;
      transform: translateY(-2px);
    }
    @keyframes spin {
      to { transform: rotate(360deg); }
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>🤖 AI Services Demo</h1>
    <p class="subtitle">Cloudflare Workers + Logto + DeepSeek</p>
    <div style="text-align: center; margin-bottom: 20px;">
      <a href="/docs" class="docs-link">📚 View API Documentation</a>
    </div>
    <div id="status" class="status info">Initializing...</div>
    <div id="loginSection" style="display: none;">
      <button class="primary" onclick="handleLogin()">🔐 Sign in with Logto</button>
      <p style="text-align: center; margin-top: 20px; font-size: 12px; color: #999;">
        You will be redirected to Logto for authentication
      </p>
    </div>
    <div id="userSection" style="display: none;">
      <div class="input-group">
        <label for="prompt">💬 Enter your question</label>
        <textarea id="prompt" placeholder="e.g. Explain what AI is in one sentence"></textarea>
      </div>
      <button class="primary" onclick="handleSubmit()" id="submitBtn">🚀 Send</button>
      <button class="secondary" onclick="handleLogout()">Sign out</button>
      <div id="result" class="result"></div>
    </div>
  </div>
  <script type="module">
    import LogtoClient from 'https://esm.sh/@logto/browser@2';
    
    const config = {
      endpoint: '${c.env.LOGTO_ENDPOINT}',
      appId: '${c.env.LOGTO_APP_ID}',
      redirectUri: window.location.origin,
    };
    
    const logtoClient = new LogtoClient(config);
    let accessToken = null;
    
    async function initLogto() {
      try {
        // Handle OAuth callback
        if (window.location.search.includes('code=')) {
          updateStatus('Processing sign-in...', 'info');
          await logtoClient.handleSignInCallback(window.location.href);
          window.history.replaceState({}, document.title, '/');
        }
        
        // Check authentication status
        const isAuthenticated = await logtoClient.isAuthenticated();
        
        if (isAuthenticated) {
          try {
            // Get idToken (standard JWT)
            const appId = config.appId;
            const idTokenKey = \`logto:\${appId}:idToken\`;
            accessToken = localStorage.getItem(idTokenKey);
            console.log('Got idToken (JWT):', accessToken ? 'yes' : 'no');
            
            const user = await logtoClient.fetchUserInfo();
            showUserSection(user);
          } catch (e) {
            console.error('Get user info error:', e);
            showLoginSection();
          }
        } else {
          showLoginSection();
        }
      } catch (error) {
        console.error('Logto initialization error:', error);
        updateStatus('❌ Initialization failed: ' + error.message, 'error');
        showLoginSection();
      }
    }
    
    function showLoginSection() {
      updateStatus('👋 Welcome! Please sign in first', 'info');
      document.getElementById('loginSection').style.display = 'block';
      document.getElementById('userSection').style.display = 'none';
    }
    
    function showUserSection(user) {
      updateStatus(\`✅ Signed in: \${user.email || user.username || user.sub}\`, 'success');
      document.getElementById('loginSection').style.display = 'none';
      document.getElementById('userSection').style.display = 'block';
    }
    
    async function handleLogin() {
      try {
        await logtoClient.signIn(config.redirectUri);
      } catch (error) {
        updateStatus('❌ Sign-in failed: ' + error.message, 'error');
      }
    }
    
    async function handleLogout() {
      try {
        await logtoClient.signOut(config.redirectUri);
        accessToken = null;
      } catch (error) {
        updateStatus('❌ Sign-out failed: ' + error.message, 'error');
      }
    }
    
    async function handleSubmit() {
      const prompt = document.getElementById('prompt').value.trim();
      
      if (!prompt) {
        updateStatus('⚠️ Please enter a question', 'error');
        return;
      }
      
      if (!accessToken) {
        updateStatus('❌ Not signed in; please refresh and try again', 'error');
        return;
      }
      
      const submitBtn = document.getElementById('submitBtn');
      const resultDiv = document.getElementById('result');
      
      submitBtn.disabled = true;
      submitBtn.textContent = '⏳ Processing...';
      resultDiv.innerHTML = '<div class="loading"><div class="spinner"></div><p>AI is thinking...</p></div>';
      resultDiv.classList.add('show');
      
      try {
        const response = await fetch('/api/v1/demo/tasks', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': \`Bearer \${accessToken}\`
          },
          body: JSON.stringify({ prompt })
        });
        
        const data = await response.json();
        
        if (data.success) {
          resultDiv.innerHTML = \`
            <h3>✨ AI Response</h3>
            <p>\${data.task.response}</p>
            <div class="quota">
              <div class="quota-item">
                <div class="quota-label">Used</div>
                <div class="quota-value">\${data.quota.used}</div>
              </div>
              <div class="quota-item">
                <div class="quota-label">Remaining</div>
                <div class="quota-value">\${data.quota.remaining}</div>
              </div>
              <div class="quota-item">
                <div class="quota-label">Tokens Used</div>
                <div class="quota-value">\${data.task.tokensUsed}</div>
              </div>
            </div>
          \`;
          updateStatus('✅ Request succeeded', 'success');
        } else {
          throw new Error(data.error || 'Unknown error');
        }
      } catch (error) {
        console.error('Submit error:', error);
        resultDiv.innerHTML = \`<p style="color: #c62828;">❌ \${error.message}</p>\`;
        updateStatus('❌ Request failed', 'error');
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = '🚀 Send';
      }
    }
    
    function updateStatus(message, type) {
      const statusDiv = document.getElementById('status');
      statusDiv.textContent = message;
      statusDiv.className = \`status \${type}\`;
    }
    
    // Expose functions to global scope
    window.handleLogin = handleLogin;
    window.handleLogout = handleLogout;
    window.handleSubmit = handleSubmit;
    
    // Initialize on load
    initLogto();
  </script>
</body>
</html>`;
  return c.html(html);
});

// ============================================
// Health Check & System Status
// ============================================

const healthRoute = createRoute({
  method: 'get',
  path: '/api/v1/health',
  tags: ['Health'],
  summary: 'Health check',
  description: 'Check the health status of all system components including database, KV store, and configuration',
  responses: {
    200: {
      description: 'System is healthy',
      content: {
        'application/json': {
          schema: HealthCheckResponseSchema,
        },
      },
    },
    503: {
      description: 'System is degraded',
      content: {
        'application/json': {
          schema: HealthCheckResponseSchema,
        },
      },
    },
  },
});

app.openapi(healthRoute, async (c) => {
  const checks = {
    database: false,
    kv: false,
    config: false,
  };

  try {
    const dbTest = await c.env.DB.prepare('SELECT 1 as test').first();
    checks.database = dbTest?.test === 1;
  } catch (error) {
    console.error('DB check failed:', error);
  }

  try {
    await c.env.AI_KV.put('health_check', Date.now().toString(), { expirationTtl: 60 });
    const kvTest = await c.env.AI_KV.get('health_check');
    checks.kv = !!kvTest;
  } catch (error) {
    console.error('KV check failed:', error);
  }

  checks.config = !!(c.env.LOGTO_ENDPOINT && c.env.DEEPSEEK_API_KEY);

  const allHealthy = Object.values(checks).every(Boolean);

  return c.json({
    status: allHealthy ? 'healthy' : 'degraded',
    checks,
    deploy: DEPLOY_INFO,
    timestamp: new Date().toISOString(),
  } as const, allHealthy ? 200 : 503);
});

const systemInfoRoute = createRoute({
  method: 'get',
  path: '/api/v1/info',
  tags: ['Health'],
  summary: 'System information',
  description: 'Get system environment, enabled features, and available endpoints',
  responses: {
    200: {
      description: 'System information',
      content: {
        'application/json': {
          schema: SystemInfoResponseSchema,
        },
      },
    },
  },
});

app.openapi(systemInfoRoute, (c) => {
  return c.json({
    environment: c.env.ENVIRONMENT || 'development',
    deploy: DEPLOY_INFO,
    features: {
      database: !!c.env.DB,
      kv: !!c.env.AI_KV,
      r2: !!c.env.FILES,
      deepseek: !!c.env.DEEPSEEK_API_KEY,
      logto: !!c.env.LOGTO_ENDPOINT,
    },
    endpoints: {
      health: '/api/v1/health',
      users: '/api/v1/demo/users',
      tasks: '/api/v1/demo/tasks',
      quota: '/api/v1/demo/quota/:userId',
    },
  });
});

// ============================================
// Demo: Database Operations
// ============================================

const listUsersRoute = createRoute({
  method: 'get',
  path: '/api/v1/demo/users',
  tags: ['Users'],
  summary: 'List users',
  description: 'Retrieve a list of users from the database (limited to 10 most recent)',
  responses: {
    200: {
      description: 'Successfully retrieved users',
      content: {
        'application/json': {
          schema: ListUsersResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: UserErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(listUsersRoute, async (c) => {
  try {
    const { results } = await c.env.DB.prepare(
      'SELECT id, email, tier, created_at FROM users ORDER BY created_at DESC LIMIT 10'
    ).all();

    return c.json({
      success: true,
      count: results.length,
      users: results,
    } as const);
  } catch (error: any) {
    console.error('API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
      stack: error.stack,
    } as const, 500);
  }
});

const createUserRoute = createRoute({
  method: 'post',
  path: '/api/v1/demo/users',
  tags: ['Users'],
  summary: 'Create a test user',
  description: 'Create a new test user in the database',
  request: {
    body: {
      content: {
        'application/json': {
          schema: CreateUserRequestSchema,
        },
      },
    },
  },
  responses: {
    200: {
      description: 'Successfully created user',
      content: {
        'application/json': {
          schema: CreateUserResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: UserErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(createUserRoute, async (c) => {
  try {
    const body = c.req.valid('json');
    const userId = `user_${Date.now()}`;
    const timestamp = Date.now();

    const emailVal = body.email || `test_${timestamp}@example.com`;
    const tierVal = body.tier || 'free';
    const existingDemo = await c.env.DB.prepare('SELECT id FROM users WHERE email = ?').bind(emailVal).first<{ id: string }>();
    if (existingDemo) {
      await c.env.DB.prepare('UPDATE users SET tier = ?, updated_at = ? WHERE email = ?')
        .bind(tierVal, timestamp, emailVal).run();
    } else {
      await c.env.DB.prepare(
        'INSERT INTO users (id, email, tier, created_at, updated_at) VALUES (?, ?, ?, ?, ?)'
      ).bind(userId, emailVal, tierVal, timestamp, timestamp).run();
    }

    return c.json({
      success: true,
      user: {
        id: userId,
        email: body.email || `test_${timestamp}@example.com`,
        tier: body.tier || 'free',
        created_at: timestamp,
      },
    } as const);
  } catch (error: any) {
    console.error('API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
      stack: error.stack,
    } as const, 500);
  }
});

// ============================================
// Demo: KV Operations (Quota Tracking)
// ============================================

const getQuotaRoute = createRoute({
  method: 'get',
  path: '/api/v1/demo/quota/{userId}',
  tags: ['Quota'],
  summary: 'Get user quota',
  description: 'Retrieve current usage quota for a specific user',
  request: {
    params: z.object({
      userId: z.string().describe('User ID'),
    }),
  },
  responses: {
    200: {
      description: 'Successfully retrieved quota',
      content: {
        'application/json': {
          schema: QuotaResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: QuotaErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(getQuotaRoute, async (c) => {
  const { userId } = c.req.valid('param');
  const quotaKey = `quota:${userId}`;

  try {
    const currentUsage = await c.env.AI_KV.get(quotaKey);
    
    return c.json({
      success: true,
      userId,
      currentUsage: parseInt(currentUsage || '0'),
      limit: 100,
      remaining: 100 - parseInt(currentUsage || '0'),
    } as const);
  } catch (error: any) {
    console.error('API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
      stack: error.stack,
    } as const, 500);
  }
});

const incrementQuotaRoute = createRoute({
  method: 'post',
  path: '/api/v1/demo/quota/{userId}/increment',
  tags: ['Quota'],
  summary: 'Increment usage',
  description: 'Increment the usage counter for a specific user',
  request: {
    params: z.object({
      userId: z.string().describe('User ID'),
    }),
  },
  responses: {
    200: {
      description: 'Successfully incremented quota',
      content: {
        'application/json': {
          schema: QuotaIncrementResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: QuotaErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(incrementQuotaRoute, async (c) => {
  const { userId } = c.req.valid('param');
  const quotaKey = `quota:${userId}`;

  try {
    const currentUsage = await c.env.AI_KV.get(quotaKey);
    const newUsage = parseInt(currentUsage || '0') + 1;
    
    await c.env.AI_KV.put(quotaKey, newUsage.toString());

    return c.json({
      success: true,
      userId,
      previousUsage: parseInt(currentUsage || '0'),
      currentUsage: newUsage,
      remaining: 100 - newUsage,
    } as const);
  } catch (error: any) {
    console.error('API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
      stack: error.stack,
    } as const, 500);
  }
});

const getQuotaHistoryRoute = createRoute({
  method: 'get',
  path: '/api/v1/demo/quota-history/{userId}',
  tags: ['Quota'],
  summary: 'Get quota history',
  description: 'Retrieve the quota usage history for a specific user',
  request: {
    params: z.object({
      userId: z.string().describe('User ID'),
    }),
  },
  responses: {
    200: {
      description: 'Successfully retrieved quota history',
      content: {
        'application/json': {
          schema: QuotaHistoryResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: QuotaErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(getQuotaHistoryRoute, async (c) => {
  const { userId } = c.req.valid('param');

  try {
    const { results } = await c.env.DB.prepare(
      'SELECT * FROM quota_history WHERE user_id = ? ORDER BY timestamp DESC LIMIT 50'
    ).bind(userId).all();

    return c.json({
      success: true,
      userId,
      count: results.length,
      history: results,
    } as const);
  } catch (error: any) {
    console.error('API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
      stack: error.stack,
    } as const, 500);
  }
});

// ============================================
// Demo: AI Task Creation & Tracking
// ============================================

const createTaskRoute = createRoute({
  method: 'post',
  path: '/api/v1/demo/tasks',
  tags: ['Tasks'],
  summary: 'Create an AI task',
  description: 'Create a new AI task with the provided prompt. Requires authentication via JWT token in Authorization header.',
  security: [{ bearerAuth: [] }],
  request: {
    body: {
      content: {
        'application/json': {
          schema: CreateTaskRequestSchema,
        },
      },
    },
  },
  responses: {
    200: {
      description: 'Successfully created task',
      content: {
        'application/json': {
          schema: CreateTaskResponseSchema,
        },
      },
    },
    401: {
      description: 'Unauthorized - missing or invalid token',
      content: {
        'application/json': {
          schema: TaskErrorResponseSchema,
        },
      },
    },
    429: {
      description: 'Quota exceeded',
      content: {
        'application/json': {
          schema: QuotaExceededResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: TaskErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(createTaskRoute, async (c) => {
  try {
    // Extract and validate JWT token
    const authHeader = c.req.header('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return c.json({ success: false, error: 'Missing or invalid Authorization header' } as const, 401);
    }

    const token = authHeader.substring(7);
    
    // Simple JWT decode
    let payload;
    try {
      const parts = token.split('.');
      if (parts.length !== 3) {
        return c.json({ 
          success: false, 
          error: `Invalid JWT format: expected 3 parts, got ${parts.length}` 
        } as const, 401);
      }
      
      const base64Url = parts[1];
      const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
      const jsonPayload = decodeURIComponent(
        atob(base64)
          .split('')
          .map((c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
          .join('')
      );
      payload = JSON.parse(jsonPayload);
    } catch (e: any) {
      console.error('JWT decode error:', e);
      return c.json({ success: false, error: 'Invalid JWT token: ' + e.message } as const, 401);
    }
    
    const logtoUserId = payload.sub;
    
    if (!logtoUserId) {
      return c.json({ success: false, error: 'Invalid token: missing sub claim' } as const, 401);
    }

    // Find or create user in database
    let user = await c.env.DB.prepare(
      'SELECT * FROM users WHERE id = ?'
    ).bind(logtoUserId).first();

    if (!user) {
      const email = payload.email || '';
      const now = Date.now();

      // Same email, different Logto sub — use the existing row
      if (email) {
        user = await c.env.DB.prepare('SELECT * FROM users WHERE email = ?').bind(email).first();
      }
      if (!user) {
        await c.env.DB.prepare(
          'INSERT INTO users (id, email, tier, created_at, updated_at) VALUES (?, ?, ?, ?, ?)'
        ).bind(logtoUserId, email, 'free', now, now).run();
        user = { id: logtoUserId, email, tier: 'free', created_at: now, updated_at: now };
      }
    }

    const userId = user.id as string;
    const body = c.req.valid('json');
    const taskId = `task_${Date.now()}`;
    const timestamp = Date.now();

    // Check quota
    const quotaKey = `quota:${userId}`;
    const currentUsage = await c.env.AI_KV.get(quotaKey);
    const usage = parseInt(currentUsage || '0');

    if (usage >= 100) {
      return c.json({
        success: false,
        error: 'Quota exceeded',
        currentUsage: usage,
        limit: 100,
      } as const, 429);
    }

    // Create task in database
    await c.env.DB.prepare(
      'INSERT INTO tasks (id, user_id, status, tokens_used, created_at) VALUES (?, ?, ?, ?, ?)'
    ).bind(taskId, userId, 'pending', 0, timestamp).run();

    // Simulate AI call
    let aiResponse = null;
    let tokensUsed = 0;

    if (c.env.DEEPSEEK_API_KEY && body.prompt) {
      try {
        const response = await fetch('https://api.deepseek.com/v1/chat/completions', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${c.env.DEEPSEEK_API_KEY}`,
          },
          body: JSON.stringify({
            model: 'deepseek-chat',
            messages: [
              { role: 'user', content: body.prompt }
            ],
            max_tokens: 100,
          }),
        });

        if (response.ok) {
          const data: any = await response.json();
          aiResponse = data.choices[0].message.content;
          tokensUsed = data.usage?.total_tokens || 10;

          await c.env.DB.prepare(
            'UPDATE tasks SET status = ?, tokens_used = ?, completed_at = ? WHERE id = ?'
          ).bind('completed', tokensUsed, Date.now(), taskId).run();

          await c.env.AI_KV.put(quotaKey, (usage + 1).toString());

          await c.env.DB.prepare(
            'INSERT INTO quota_history (id, user_id, task_id, tokens_used, timestamp) VALUES (?, ?, ?, ?, ?)'
          ).bind(`history_${Date.now()}`, userId, taskId, tokensUsed, Date.now()).run();
        } else {
          await c.env.DB.prepare(
            'UPDATE tasks SET status = ?, error_message = ? WHERE id = ?'
          ).bind('failed', `API error: ${response.status}`, taskId).run();
        }
      } catch (error: any) {
        await c.env.DB.prepare(
          'UPDATE tasks SET status = ?, error_message = ? WHERE id = ?'
        ).bind('failed', error.message, taskId).run();
      }
    } else {
      aiResponse = 'Mock AI response (no API key or prompt provided)';
      tokensUsed = 10;
      
      await c.env.DB.prepare(
        'UPDATE tasks SET status = ?, tokens_used = ?, completed_at = ? WHERE id = ?'
      ).bind('completed', tokensUsed, Date.now(), taskId).run();

      await c.env.AI_KV.put(quotaKey, (usage + 1).toString());
    }

    return c.json({
      success: true,
      task: {
        id: taskId,
        userId,
        status: 'completed',
        response: aiResponse,
        tokensUsed,
      },
      quota: {
        used: usage + 1,
        remaining: 99 - usage,
      },
    } as const);
  } catch (error: any) {
    console.error('API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
      stack: error.stack,
    } as const, 500);
  }
});

const listTasksRoute = createRoute({
  method: 'get',
  path: '/api/v1/demo/tasks',
  tags: ['Tasks'],
  summary: 'List tasks',
  description: 'Retrieve a list of recent tasks (limited to 20)',
  responses: {
    200: {
      description: 'Successfully retrieved tasks',
      content: {
        'application/json': {
          schema: ListTasksResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: TaskErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(listTasksRoute, async (c) => {
  try {
    const { results } = await c.env.DB.prepare(
      'SELECT id, user_id, status, tokens_used, created_at, completed_at FROM tasks ORDER BY created_at DESC LIMIT 20'
    ).all();

    return c.json({
      success: true,
      count: results.length,
      tasks: results,
    } as const);
  } catch (error: any) {
    console.error('API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
      stack: error.stack,
    } as const, 500);
  }
});

// ============================================
// LLM Postprocess API
// ============================================

const llmPostprocessRoute = createRoute({
  method: 'post',
  path: '/api/v1/llm/postprocess',
  tags: ['LLM'],
  summary: 'LLM text postprocessing',
  description: 'Process ASR transcript via AI Worker with provider fallback. Requires authentication.',
  middleware: [authMiddleware] as any,
  request: {
    body: {
      content: {
        'application/json': {
          schema: LLMPostprocessRequestSchema,
        },
      },
    },
  },
  responses: {
    200: {
      description: 'Successfully processed text',
      content: {
        'application/json': {
          schema: LLMPostprocessSuccessResponseSchema,
        },
      },
    },
    401: {
      description: 'Unauthorized - missing or invalid token',
      content: {
        'application/json': {
          schema: LLMPostprocessErrorResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: LLMPostprocessErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(llmPostprocessRoute, async (c) => {
  try {
    const userId = c.get('userId') as string;

    const userTier = await resolveUserTier(c.env.DB, userId);
    const customLimits = await fetchCustomLimits(c.env.AI_KV, userId);

    // Check rate limit quota
    const quotaCheck = await checkLLMQuota(c.env.AI_KV, userId, userTier, customLimits);
    
    if (!quotaCheck.allowed) {
      console.warn(`[Rate Limit] LLM quota exceeded for user ${userId}`);
      return c.json({
        success: false,
        error: 'Rate limit exceeded',
        rateLimitInfo: {
          type: 'llm' as const,
          tier: userTier,
          limit: quotaCheck.limit,
          used: quotaCheck.current,
          remaining: quotaCheck.remaining,
          resetAt: quotaCheck.resetAt.toISOString(),
          resetIn: quotaCheck.resetIn,
        },
      } as const, 429);
    }

    const body = c.req.valid('json');
    const model = 'server-managed';

    // Offload quota consume + audit to AI_WORKER (own CPU budget)
    offloadMetering(c.env.AI_WORKER, c.executionCtx, {
      action: 'consume_llm', userId, amount: 1, tier: userTier,
      metadata: { model },
    });

    const clientCountry = (c.req.raw.cf as any)?.country || '';

    // Forward structured data to AI Worker via Service Binding
    try {
      const response = await c.env.AI_WORKER.fetch(
        new Request('https://ai-worker/v1/postprocess', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(clientCountry ? { 'X-Client-Country': clientCountry } : {}),
          },
          body: JSON.stringify(body),
        })
      );

      if (!response.ok) {
        const errorText = await response.text();
        console.error('[LLM Postprocess] AI Worker error:', response.status, errorText);
        return c.json({
          success: false,
          error: `AI Worker error: ${response.status}`,
        } as const, response.status as any);
      }

      return new Response(response.body, {
        status: response.status,
        headers: {
          'Content-Type': response.headers.get('Content-Type') || 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
        },
      });
    } catch (fetchError: any) {
      console.error('[LLM Postprocess] AI Worker call failed:', fetchError);
      return c.json({
        success: false,
        error: fetchError.message || 'Failed to call AI Worker',
      } as const, 500);
    }
  } catch (error: any) {
    console.error('LLM Postprocess API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
    } as const, 500);
  }
});

// ============================================
// Generic Chat Completion API (used by features like scenario matching)
// ============================================

const llmChatRoute = createRoute({
  method: 'post',
  path: '/api/v1/llm/chat',
  tags: ['LLM'],
  summary: 'Generic LLM chat completion',
  description: 'Proxy generic chat completions via AI Worker. Requires authentication.',
  middleware: [authMiddleware] as any,
  request: {
    body: {
      content: {
        'application/json': {
          schema: ChatCompletionRequestSchema,
        },
      },
    },
  },
  responses: {
    200: {
      description: 'Successfully processed',
      content: {
        'application/json': {
          schema: LLMPostprocessSuccessResponseSchema,
        },
      },
    },
    401: {
      description: 'Unauthorized',
      content: {
        'application/json': {
          schema: LLMPostprocessErrorResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: LLMPostprocessErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(llmChatRoute, async (c) => {
  try {
    const userId = c.get('userId') as string;

    const userTier = await resolveUserTier(c.env.DB, userId);
    const customLimits = await fetchCustomLimits(c.env.AI_KV, userId);
    const quotaCheck = await checkLLMQuota(c.env.AI_KV, userId, userTier, customLimits);

    if (!quotaCheck.allowed) {
      return c.json({
        success: false,
        error: 'Rate limit exceeded',
        rateLimitInfo: {
          type: 'llm' as const,
          tier: userTier,
          limit: quotaCheck.limit,
          used: quotaCheck.current,
          remaining: quotaCheck.remaining,
          resetAt: quotaCheck.resetAt.toISOString(),
          resetIn: quotaCheck.resetIn,
        },
      } as const, 429);
    }

    const body = c.req.valid('json');

    offloadMetering(c.env.AI_WORKER, c.executionCtx, {
      action: 'consume_llm', userId, amount: 1, tier: userTier,
      metadata: { model: 'chat' },
    });

    const chatClientCountry = (c.req.raw.cf as any)?.country || '';

    try {
      const response = await c.env.AI_WORKER.fetch(
        new Request('https://ai-worker/v1/chat', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(chatClientCountry ? { 'X-Client-Country': chatClientCountry } : {}),
          },
          body: JSON.stringify(body),
        })
      );

      if (!response.ok) {
        const errorText = await response.text();
        console.error('[LLM Chat] AI Worker error:', response.status, errorText);
        return c.json({
          success: false,
          error: `AI Worker error: ${response.status}`,
        } as const, response.status as any);
      }

      return new Response(response.body, {
        status: response.status,
        headers: {
          'Content-Type': response.headers.get('Content-Type') || 'text/event-stream',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
        },
      });
    } catch (fetchError: any) {
      console.error('[LLM Chat] AI Worker call failed:', fetchError);
      return c.json({
        success: false,
        error: fetchError.message || 'Failed to call AI Worker',
      } as const, 500);
    }
  } catch (error: any) {
    console.error('LLM Chat API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
    } as const, 500);
  }
});

// ============================================
// Rate Limit Status Query
// ============================================

const rateLimitStatusRoute = createRoute({
  method: 'get',
  path: '/api/v1/rate-limit/status',
  tags: ['Rate Limit'],
  summary: 'Get rate limit status',
  description: 'Get current rate limit usage and remaining quota for the authenticated user',
  security: [{ bearerAuth: [] }],
  responses: {
    200: {
      description: 'Successfully retrieved rate limit status',
      content: {
        'application/json': {
          schema: QuotaStatusResponseSchema,
        },
      },
    },
    401: {
      description: 'Unauthorized - missing or invalid token',
      content: {
        'application/json': {
          schema: QuotaStatusErrorResponseSchema,
        },
      },
    },
    500: {
      description: 'Internal server error',
      content: {
        'application/json': {
          schema: QuotaStatusErrorResponseSchema,
        },
      },
    },
  },
});

app.openapi(rateLimitStatusRoute, async (c) => {
  try {
    // Extract and validate JWT token
    const authHeader = c.req.header('Authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return c.json({ 
        success: false, 
        error: 'Missing or invalid Authorization header' 
      } as const, 401);
    }

    const token = authHeader.substring(7);
    
    // Simple JWT decode
    let payload;
    try {
      const parts = token.split('.');
      if (parts.length !== 3) {
        return c.json({ 
          success: false, 
          error: `Invalid JWT format: expected 3 parts, got ${parts.length}` 
        } as const, 401);
      }
      
      const base64Url = parts[1];
      const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
      const jsonPayload = decodeURIComponent(
        atob(base64)
          .split('')
          .map((c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2))
          .join('')
      );
      payload = JSON.parse(jsonPayload);
    } catch (e: any) {
      console.error('JWT decode error:', e);
      return c.json({ 
        success: false, 
        error: 'Invalid JWT token: ' + e.message 
      } as const, 401);
    }
    
    const userId = payload.sub;
    if (!userId) {
      return c.json({ 
        success: false, 
        error: 'Invalid token: missing sub claim' 
      } as const, 401);
    }

    // Find user in database — by id first, then by email fallback
    let effectiveUserId = userId;
    let user = await c.env.DB.prepare(
      'SELECT id, tier FROM users WHERE id = ?'
    ).bind(userId).first<{ id: string; tier: string }>();

    if (!user) {
      const email = payload.email || '';
      // Same email, different Logto sub — use the existing DB row as-is
      // (authMiddleware will handle the id merge on next auth-protected request)
      if (email) {
        const byEmail = await c.env.DB.prepare(
          'SELECT id, tier FROM users WHERE email = ?'
        ).bind(email).first<{ id: string; tier: string }>();
        if (byEmail) {
          user = byEmail;
          effectiveUserId = byEmail.id;
        }
      }
      // Truly new user — create
      if (!user) {
        const now = Date.now();
        await c.env.DB.prepare(
          'INSERT INTO users (id, email, tier, created_at, updated_at) VALUES (?, ?, ?, ?, ?)'
        ).bind(userId, email, 'free', now, now).run();
      }
    }

    // Use effectiveUserId so subscription/quota lookups match the DB
    const { tier: userTier, subscription } = await resolveUserTierWithInfo(c.env.DB, effectiveUserId);
    const customLimits = await fetchCustomLimits(c.env.AI_KV, effectiveUserId);

    // Get quota status
    const status = await getQuotaStatus(c.env.AI_KV, effectiveUserId, userTier, customLimits, c.env.DB);

    return c.json({
      success: true,
      ...status,
      ...(customLimits ? { customLimits } : {}),
      subscription,
    } as const);
  } catch (error: any) {
    console.error('Rate Limit Status API Error:', error);
    return c.json({
      success: false,
      error: error.message || String(error),
    } as const, 500);
  }
});

// ============================================
// Identity (Public, auth required)
// ============================================

app.get('/api/v1/identities', authMiddleware, async (c) => {
  const raw = await c.env.AI_KV.get<IdentityIndex[]>(IDENTITIES_INDEX_KEY, 'json');
  const index = (raw ?? []).filter((p) => p.enabled);
  return c.json({ success: true, data: index });
});

app.get('/api/v1/identities/:id', authMiddleware, async (c) => {
  const id = c.req.param('id');
  const identity = await c.env.AI_KV.get<Identity>(`${IDENTITY_PREFIX}${id}`, 'json');
  if (!identity || !identity.enabled) {
    return c.json({ success: false, error: 'Identity not found' }, 404);
  }
  return c.json({ success: true, data: identity });
});

// ============================================
// Backward Compatibility Routes (deprecated)
// ============================================

app.get('/api/v1/correction-packs', authMiddleware, async (c) => {
  const raw = await c.env.AI_KV.get<IdentityIndex[]>(IDENTITIES_INDEX_KEY, 'json');
  const index = (raw ?? []).filter((p) => p.enabled);
  return c.json({ success: true, data: index });
});

app.get('/api/v1/correction-packs/:id', authMiddleware, async (c) => {
  const id = c.req.param('id');
  const identity = await c.env.AI_KV.get<Identity>(`${IDENTITY_PREFIX}${id}`, 'json');
  if (!identity || !identity.enabled) {
    return c.json({ success: false, error: 'Correction pack not found' }, 404);
  }
  return c.json({ success: true, data: identity });
});

// ============================================
// Mount Routes
// ============================================
app.route('/auth', authRouter);
app.route('/api/v1/admin-auth', adminAuthRouter);
app.route('/api/v1/admin', adminRouter);
app.route('/api/app/updates', createAppUpdateRouter());
app.route('/api/v1/app/mac/updates', createMacUpdateRouter());
app.route('/api/v1/hotwords', hotwordsRouter);
app.route('/api/v1', paymentRouter);

// ============================================
// Error Handlers
// ============================================

app.onError((err, c) => {
  console.error('Global error:', err);
  
  // If it's an HTTPException, preserve the status code
  if ('status' in err && typeof err.status === 'number') {
    return c.json(
      {
        error: err.message,
        timestamp: new Date().toISOString(),
      },
      err.status
    );
  }
  
  // Otherwise return 500 for unknown errors
  return c.json(
    {
      error: 'Internal Server Error',
      message: err.message,
      timestamp: new Date().toISOString(),
    },
    500
  );
});

app.notFound((c) => {
  return c.json(
    {
      error: 'Not Found',
      path: c.req.path,
      timestamp: new Date().toISOString(),
    },
    404
  );
});

// ============================================
// Scheduled Tasks (Cron Triggers)
// ============================================

/**
 * Scheduled task handler for cron triggers
 * - Daily at 19:00 UTC (03:00 Beijing Time): LLM quota reset
 * - Monday at 19:00 UTC (03:00 Beijing Time): ASR quota reset
 * 
 * Note: KV entries with TTL will auto-expire, so no manual cleanup needed
 * This handler is mainly for logging and monitoring
 */
async function handleScheduled(
  event: ScheduledEvent,
  env: Bindings,
  ctx: ExecutionContext
): Promise<void> {
  const now = new Date();
  const dayOfWeek = now.getUTCDay(); // 0 = Sunday, 1 = Monday, etc.
  
  console.log('[Scheduled Task] Triggered at:', now.toISOString());
  console.log('[Scheduled Task] Cron:', event.cron);
  
  // Determine which reset is happening
  if (dayOfWeek === 1) {
    // Monday - ASR quota reset (weekly)
    console.log('[Scheduled Task] ASR weekly quota reset (Monday 03:00 Beijing Time)');
  } else {
    // Daily - LLM quota reset
    console.log('[Scheduled Task] LLM daily quota reset (03:00 Beijing Time)');
  }

  // Optional: Log reset event to database for monitoring
  try {
    const logId = `reset_${Date.now()}_${Math.random().toString(36).substring(2, 10)}`;
    await env.DB.prepare(
      'INSERT INTO rate_limit_history (id, user_id, type, metric, amount, tier, metadata, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
    ).bind(
      logId,
      'system',
      dayOfWeek === 1 ? 'asr' : 'llm',
      'reset',
      0,
      'system',
      JSON.stringify({ cron: event.cron, scheduledTime: event.scheduledTime }),
      Date.now()
    ).run();

    console.log('[Scheduled Task] Reset logged to database');
  } catch (error) {
    console.error('[Scheduled Task] Failed to log reset:', error);
  }

  // Subscription audit — runs on every cron trigger (daily)
  try {
    console.log('[Scheduled Task] Running subscription audit...');
    const auditResult = await runSubscriptionAudit({
      DB: env.DB,
      CREEM_API_KEY: env.CREEM_API_KEY,
      ENVIRONMENT: env.ENVIRONMENT,
    });
    console.log('[Scheduled Task] Subscription audit complete:', JSON.stringify(auditResult));
  } catch (error) {
    console.error('[Scheduled Task] Subscription audit failed:', error);
  }
}

// Export default worker with fetch and scheduled handlers
/**
 * Fire-and-forget metering via AI_WORKER service binding.
 * Each call triggers a new Worker invocation with its own CPU budget.
 */
function offloadMetering(
  aiWorker: Fetcher,
  executionCtx: ExecutionContext,
  payload: {
    action: 'consume_duration' | 'consume_characters' | 'refund_duration' | 'refund_characters' | 'consume_llm' | 'audit';
    userId: string;
    amount: number;
    tier: string;
    metadata?: Record<string, any>;
  },
) {
  executionCtx.waitUntil(
    aiWorker.fetch(new Request('https://ai-worker/v1/metering', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })).then((res) => {
      if (!res.ok) console.warn(`[Metering] offload ${payload.action} failed: ${res.status}`);
    }).catch((e) => console.warn(`[Metering] offload ${payload.action} error:`, (e as Error).message)),
  );
}

export default {
  async fetch(
    request: Request,
    env: Bindings,
    ctx: ExecutionContext,
  ): Promise<Response> {
    const limiter = env.IP_RATE_LIMITER;
    if (limiter) {
      const ip = request.headers.get('cf-connecting-ip') ?? request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown';
      const { success } = await limiter.limit({ key: ip });
      if (!success) {
        return new Response(
          JSON.stringify({ success: false, error: 'Too many requests' }),
          { status: 429, headers: { 'Content-Type': 'application/json' } },
        );
      }
    }
    return app.fetch(request, env, ctx);
  },
  scheduled: handleScheduled,
};