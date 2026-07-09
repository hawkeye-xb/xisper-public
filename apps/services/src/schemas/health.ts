import { z } from 'zod';

const DeployInfoSchema = z.object({
  gitHash: z.string(),
  gitShort: z.string(),
  gitBranch: z.string(),
  gitDirty: z.boolean(),
  gitMessage: z.string(),
  deployTime: z.string(),
  deployer: z.string(),
  app: z.string(),
  env: z.string(),
});

// Health check response
export const HealthCheckResponseSchema = z.object({
  status: z.enum(['healthy', 'degraded']).describe('Overall system status'),
  checks: z.object({
    database: z.boolean().describe('D1 database connection'),
    kv: z.boolean().describe('KV namespace connection'),
    config: z.boolean().describe('Environment configuration'),
  }),
  deploy: DeployInfoSchema.describe('Build-time deployment metadata'),
  timestamp: z.string().datetime().describe('ISO 8601 timestamp'),
});

// System info response
export const SystemInfoResponseSchema = z.object({
  environment: z.string().describe('Current environment'),
  deploy: DeployInfoSchema.describe('Build-time deployment metadata'),
  features: z.object({
    database: z.boolean(),
    kv: z.boolean(),
    r2: z.boolean(),
    deepseek: z.boolean(),
    logto: z.boolean(),
  }),
  endpoints: z.object({
    health: z.string(),
    users: z.string(),
    tasks: z.string(),
    quota: z.string(),
  }),
});
