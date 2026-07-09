// Environment bindings type definition
export type Env = {
  // KV namespace for caching and quota management
  AI_KV: KVNamespace;
  
  // D1 database for persistent storage
  DB: D1Database;
  
  // R2 bucket for file storage
  FILES: R2Bucket;
  
  // Logto authentication configuration
  LOGTO_ENDPOINT: string;
  LOGTO_APP_ID: string;
  LOGTO_APP_SECRET: string;
  
  // AI API keys
  OPENAI_API_KEY: string;
  DEEPSEEK_API_KEY?: string;
  
  // Creem payment platform
  CREEM_API_KEY: string;
  PAYMENT_WEBHOOK_SECRET?: string;
  
  // Environment identifier
  ENVIRONMENT: string;
};

// User model
export interface User {
  id: string;
  email: string;
  tier: 'free' | 'pro' | 'enterprise' | 'unlimited';
  role: 'user' | 'admin';
  quota_reset_at: number;
  created_at: number;
  updated_at: number;
  metadata?: string;
}

// Task model
export interface Task {
  id: string;
  user_id: string;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  r2_key?: string;
  tokens_used: number;
  error_message?: string;
  created_at: number;
  completed_at?: number;
}

// Quota history model
export interface QuotaHistory {
  id: string;
  user_id: string;
  task_id?: string;
  tokens_used: number;
  timestamp: number;
}

// API response wrapper
export interface ApiResponse<T = any> {
  success: boolean;
  data?: T;
  error?: {
    code: string;
    message: string;
  };
  timestamp: string;
}

// JWT payload from Logto
export interface JWTPayload {
  sub: string; // User ID
  aud: string; // Audience
  iss: string; // Issuer
  exp: number; // Expiration time
  iat: number; // Issued at
  email?: string;
  [key: string]: any;
}
