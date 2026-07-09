import { z } from 'zod';

// Common response schemas
export const SuccessResponseSchema = z.object({
  success: z.literal(true),
});

export const ErrorResponseSchema = z.object({
  success: z.literal(false),
  error: z.string(),
  stack: z.string().optional(),
});

// Common types
export const TimestampSchema = z.number().int().positive().describe('Unix timestamp in milliseconds');
export const UserIdSchema = z.string().describe('User ID');
export const TaskIdSchema = z.string().describe('Task ID');
export const EmailSchema = z.string().email().describe('Email address');

// Pagination
export const PaginationParamsSchema = z.object({
  page: z.string().optional().default('1').describe('Page number'),
  limit: z.string().optional().default('10').describe('Items per page'),
});
