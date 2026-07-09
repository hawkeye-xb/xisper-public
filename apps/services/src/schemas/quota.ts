import { z } from 'zod';
import { SuccessResponseSchema, ErrorResponseSchema, UserIdSchema, TaskIdSchema, TimestampSchema } from './common';

// Quota response
export const QuotaResponseSchema = SuccessResponseSchema.extend({
  userId: UserIdSchema,
  currentUsage: z.number().int().nonnegative(),
  limit: z.number().int().positive(),
  remaining: z.number().int().nonnegative(),
});

// Quota increment response
export const QuotaIncrementResponseSchema = SuccessResponseSchema.extend({
  userId: UserIdSchema,
  previousUsage: z.number().int().nonnegative(),
  currentUsage: z.number().int().nonnegative(),
  remaining: z.number().int().nonnegative(),
});

// Quota history item
export const QuotaHistoryItemSchema = z.object({
  id: z.string(),
  user_id: UserIdSchema,
  task_id: TaskIdSchema,
  tokens_used: z.number().int().nonnegative(),
  timestamp: TimestampSchema,
});

// Quota history response
export const QuotaHistoryResponseSchema = SuccessResponseSchema.extend({
  userId: UserIdSchema,
  count: z.number().int().nonnegative(),
  history: z.array(QuotaHistoryItemSchema),
});

// Error response
export const QuotaErrorResponseSchema = ErrorResponseSchema;
