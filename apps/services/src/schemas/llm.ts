import { z } from 'zod';
import { RateLimitInfoSchema } from './rate-limit';

// Chat message (kept for backward compatibility)
export const ChatMessageSchema = z.object({
  role: z.enum(['system', 'user', 'assistant']),
  content: z.string(),
});

// Request — structured context format (sent to AI Worker)
export const LLMPostprocessRequestSchema = z.object({
  text: z.string().min(1),

  config: z.object({
    mode: z.enum(['clean', 'rewrite']).default('clean'),
    voiceMode: z.enum(['dictation', 'command', 'conversation', 'translation']).default('dictation'),
    features: z.object({
      correction: z.boolean().default(true),
      formatting: z.boolean().default(true),
      hotwords: z.boolean().default(true),
      rewrite: z.boolean().default(false),
    }),
  }),

  context: z.object({
    app: z.object({ name: z.string(), bundleId: z.string() }).optional(),
    windowTitle: z.string().optional(),
    url: z.string().optional(),
    domain: z.string().optional(),
    selectedText: z.string().optional(),
    visibleText: z.string().optional(),
    windowText: z.string().optional(),
  }).optional(),

  hotwords: z.array(z.string()).optional(),
  corrections: z.array(z.object({
    correct: z.string(),
    misheard: z.array(z.string()).optional(),
    note: z.string().optional(),
  })).optional(),

  llm: z.object({
    temperature: z.number().min(0).max(2).optional(),
    maxTokens: z.number().positive().optional(),
  }).optional(),

  translationInstruction: z.string().optional(),

  stream: z.boolean().optional().default(true),
});

// Generic chat completion request (used by features like scenario matching)
export const ChatCompletionRequestSchema = z.object({
  messages: z.array(ChatMessageSchema).min(1),
  temperature: z.number().min(0).max(2).optional(),
  maxTokens: z.number().positive().optional(),
  stream: z.boolean().optional().default(true),
});

// Response - Success
export const LLMPostprocessSuccessResponseSchema = z.object({
  success: z.literal(true),
  result: z.object({
    text: z.string(),
    provider: z.object({
      provider: z.string(),
      model: z.string(),
      requestId: z.string().optional(),
    }),
    usage: z.object({
      promptTokens: z.number().optional(),
      completionTokens: z.number().optional(),
      totalTokens: z.number().optional(),
    }).optional(),
  }),
});

// Response - Error
export const LLMPostprocessErrorResponseSchema = z.object({
  success: z.literal(false),
  error: z.string(),
  rateLimitInfo: RateLimitInfoSchema.optional(),
});

// Union type for all responses
export const LLMPostprocessResponseSchema = z.union([
  LLMPostprocessSuccessResponseSchema,
  LLMPostprocessErrorResponseSchema,
]);
