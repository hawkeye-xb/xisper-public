import { z } from 'zod';
import { SuccessResponseSchema, ErrorResponseSchema, TimestampSchema, UserIdSchema, EmailSchema } from './common';

// User model
export const UserSchema = z.object({
  id: UserIdSchema,
  email: EmailSchema,
  tier: z.enum(['free', 'pro', 'enterprise', 'unlimited']).describe('User tier'),
  created_at: TimestampSchema,
  updated_at: TimestampSchema.optional(),
});

// Create user request
export const CreateUserRequestSchema = z.object({
  email: EmailSchema.optional(),
  tier: z.enum(['free', 'pro', 'enterprise', 'unlimited']).optional().default('free'),
});

// Create user response
export const CreateUserResponseSchema = SuccessResponseSchema.extend({
  user: UserSchema,
});

// List users response
export const ListUsersResponseSchema = SuccessResponseSchema.extend({
  count: z.number().int().nonnegative(),
  users: z.array(UserSchema),
});

// Error responses
export const UserErrorResponseSchema = ErrorResponseSchema;
