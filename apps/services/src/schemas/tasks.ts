import { z } from 'zod';
import { SuccessResponseSchema, ErrorResponseSchema, TimestampSchema, TaskIdSchema, UserIdSchema } from './common';

// Task model
export const TaskSchema = z.object({
  id: TaskIdSchema,
  user_id: UserIdSchema,
  status: z.enum(['pending', 'completed', 'failed']).describe('Task status'),
  tokens_used: z.number().int().nonnegative().describe('Tokens consumed'),
  created_at: TimestampSchema,
  completed_at: TimestampSchema.optional(),
  error_message: z.string().optional(),
});

// Create task request
export const CreateTaskRequestSchema = z.object({
  prompt: z.string().min(1).max(1000).describe('User prompt for AI'),
});

// Create task response
export const CreateTaskResponseSchema = SuccessResponseSchema.extend({
  task: z.object({
    id: TaskIdSchema,
    userId: UserIdSchema,
    status: z.string(),
    response: z.string().nullable(),
    tokensUsed: z.number(),
  }),
  quota: z.object({
    used: z.number(),
    remaining: z.number(),
  }),
});

// List tasks response
export const ListTasksResponseSchema = SuccessResponseSchema.extend({
  count: z.number().int().nonnegative(),
  tasks: z.array(TaskSchema),
});

// Task error response
export const TaskErrorResponseSchema = ErrorResponseSchema;

// Quota exceeded response
export const QuotaExceededResponseSchema = ErrorResponseSchema.extend({
  currentUsage: z.number(),
  limit: z.number(),
});
