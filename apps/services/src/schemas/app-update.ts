/**
 * App Update Schemas
 * 
 * OpenAPI/Zod schemas for update API endpoints.
 */

import { z } from 'zod';

// Update channel enum
export const UpdateChannelSchema = z.enum(['beta', 'production']);

// Platform enum
export const PlatformSchema = z.enum(['darwin', 'win32', 'linux']);

// Update request query parameters
export const UpdateRequestSchema = z.object({
  channel: UpdateChannelSchema.optional().default('production'),
  platform: PlatformSchema.optional().default('darwin'),
  currentVersion: z.string().optional(),
});

// Update manifest response (YAML text)
export const UpdateManifestResponseSchema = z.string();

// Error response
export const UpdateErrorResponseSchema = z.object({
  success: z.literal(false),
  error: z.string(),
});
