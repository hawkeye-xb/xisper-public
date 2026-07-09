/**
 * Rate Limit Schemas
 * 
 * Zod schemas for rate limit API responses
 */

import { z } from 'zod';

/**
 * Rate limit info object (included in error responses)
 */
export const RateLimitInfoSchema = z.object({
  type: z.enum(['llm', 'asr']),
  tier: z.enum(['free', 'pro', 'enterprise']),
  limit: z.number(),
  used: z.number(),
  remaining: z.number(),
  resetAt: z.string(),
  resetIn: z.number(),
});

/**
 * Rate limit error response (429)
 */
export const RateLimitErrorResponseSchema = z.object({
  success: z.literal(false),
  error: z.string(),
  rateLimitInfo: RateLimitInfoSchema.optional(),
});

/**
 * LLM quota status
 */
export const LLMQuotaStatusSchema = z.object({
  limit: z.number(),
  used: z.number(),
  remaining: z.number(),
  resetAt: z.string(),
  resetIn: z.number(),
});

/**
 * ASR quota metric (duration or characters)
 */
export const ASRQuotaMetricSchema = z.object({
  limit: z.number(),
  used: z.number(),
  remaining: z.number(),
});

/**
 * ASR quota status
 */
export const ASRQuotaStatusSchema = z.object({
  duration: ASRQuotaMetricSchema,
  characters: ASRQuotaMetricSchema,
  resetAt: z.string(),
  resetIn: z.number(),
});

/**
 * Complete quota status response
 */
export const QuotaStatusResponseSchema = z.object({
  success: z.literal(true),
  userId: z.string(),
  tier: z.enum(['free', 'pro', 'enterprise']),
  llm: LLMQuotaStatusSchema,
  asr: ASRQuotaStatusSchema,
});

/**
 * Quota status error response
 */
export const QuotaStatusErrorResponseSchema = z.object({
  success: z.literal(false),
  error: z.string(),
});

// Export types
export type RateLimitInfo = z.infer<typeof RateLimitInfoSchema>;
export type RateLimitErrorResponse = z.infer<typeof RateLimitErrorResponseSchema>;
export type LLMQuotaStatus = z.infer<typeof LLMQuotaStatusSchema>;
export type ASRQuotaStatus = z.infer<typeof ASRQuotaStatusSchema>;
export type QuotaStatusResponse = z.infer<typeof QuotaStatusResponseSchema>;
export type QuotaStatusErrorResponse = z.infer<typeof QuotaStatusErrorResponseSchema>;
