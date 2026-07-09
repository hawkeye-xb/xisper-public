/**
 * Admin API client
 * Wraps fetch with auth token injection and error handling
 */

import { config } from './config'

let getTokenFn: (() => Promise<string | undefined>) | null = null

export function setTokenGetter(fn: () => Promise<string | undefined>) {
  getTokenFn = fn
}

async function request<T = any>(
  path: string,
  options: RequestInit = {}
): Promise<T> {
  const token = getTokenFn ? await getTokenFn() : undefined

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    ...(options.headers as Record<string, string>),
  }

  if (token) {
    headers['Authorization'] = `Bearer ${token}`
  }

  const res = await fetch(`${config.apiBaseUrl}${path}`, {
    ...options,
    headers,
  })

  if (!res.ok) {
    if (res.status === 401) {
      // Token expired or invalid — force re-login
      localStorage.removeItem('admin_token')
      localStorage.removeItem('admin_username')
      window.location.href = '/login'
    }
    const body = await res.json().catch(() => ({ error: res.statusText }))
    throw new ApiError(res.status, body.error || body.message || res.statusText)
  }

  return res.json()
}

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message)
    this.name = 'ApiError'
  }
}

// ============================================
// User Management
// ============================================

export interface PaginationParams {
  page?: number
  pageSize?: number
}

export interface UserListParams extends PaginationParams {
  search?: string
  tier?: string
  role?: string
  /** true = only today-active, false = only not today-active */
  activeToday?: boolean
}

export interface PaginatedResponse<T> {
  success: boolean
  data: T[]
  pagination: {
    page: number
    pageSize: number
    total: number
    totalPages: number
  }
}

export interface UserRecord {
  id: string
  email: string
  tier: string
  role: string
  created_at: number
  updated_at: number
  metadata?: string
  /** true if user has used LLM/ASR today (UTC) per rate_limit_history */
  active_today?: boolean
}

export interface CustomQuotaLimits {
  llmCalls?: number
  asrDuration?: number
  asrCharacters?: number
}

export interface QuotaStatus {
  userId: string
  tier: string
  llm: {
    limit: number
    used: number
    remaining: number
    resetAt: string
    resetIn: number
  }
  asr: {
    duration: { limit: number; used: number; remaining: number }
    characters: { limit: number; used: number; remaining: number }
    resetAt: string
    resetIn: number
  }
  customLimits?: CustomQuotaLimits | null
}

export interface SystemStats {
  totalUsers: number
  recentSignups: number
  todayActive: number
  tierDistribution: { tier: string; count: number }[]
  roleDistribution: { role: string; count: number }[]
}

// ============================================
// Identities
// ============================================

export interface CorrectionRule {
  correct: string
  misheard?: string[]
  note?: string
}

export interface HotwordEntry {
  text: string
  weight: number
  lang: string
}

export interface IdentityIndex {
  id: string
  label: string
  description?: string
  enabled: boolean
  updatedAt: number
  correctionCount: number
  vocabularyId?: string
}

export interface Identity extends IdentityIndex {
  corrections: CorrectionRule[]
  hotwords?: HotwordEntry[]
}

// ============================================
// Prompt Templates
// ============================================

export interface PromptTemplate {
  voiceMode: string
  hasCustom: boolean
  template: string | null
  defaultTemplate: string
  version: string | null
  updatedAt: string | null
  updatedBy: string | null
}

export const adminApi = {
  // Users
  listUsers(params: UserListParams = {}) {
    const qs = new URLSearchParams()
    if (params.page) qs.set('page', String(params.page))
    if (params.pageSize) qs.set('pageSize', String(params.pageSize))
    if (params.search) qs.set('search', params.search)
    if (params.tier) qs.set('tier', params.tier)
    if (params.role) qs.set('role', params.role)
    if (params.activeToday === true) qs.set('activeToday', 'true')
    return request<PaginatedResponse<UserRecord>>(`/api/v1/admin/users?${qs}`)
  },

  getUser(id: string) {
    return request<{ success: boolean; data: UserRecord & { quota: QuotaStatus } }>(
      `/api/v1/admin/users/${id}`
    )
  },

  updateTier(id: string, tier: string) {
    return request(`/api/v1/admin/users/${id}/tier`, {
      method: 'PUT',
      body: JSON.stringify({ tier }),
    })
  },

  updateRole(id: string, role: string) {
    return request(`/api/v1/admin/users/${id}/role`, {
      method: 'PUT',
      body: JSON.stringify({ role }),
    })
  },

  // Quota
  getQuota(userId: string) {
    return request<{ success: boolean; data: QuotaStatus }>(
      `/api/v1/admin/users/${userId}/quota`
    )
  },

  overrideQuota(userId: string, overrides: { llm?: number; asrDuration?: number; asrCharacters?: number }) {
    return request(`/api/v1/admin/users/${userId}/quota`, {
      method: 'PUT',
      body: JSON.stringify(overrides),
    })
  },

  resetQuota(userId: string) {
    return request(`/api/v1/admin/users/${userId}/quota`, {
      method: 'DELETE',
    })
  },

  getCustomLimits(userId: string) {
    return request<{ success: boolean; data: CustomQuotaLimits | null }>(
      `/api/v1/admin/users/${userId}/quota-limits`
    )
  },

  setCustomLimits(userId: string, limits: Partial<CustomQuotaLimits>) {
    return request<{ success: boolean; data: { userId: string; customLimits: CustomQuotaLimits | null } }>(
      `/api/v1/admin/users/${userId}/quota-limits`,
      { method: 'PUT', body: JSON.stringify(limits) },
    )
  },

  clearCustomLimits(userId: string) {
    return request(`/api/v1/admin/users/${userId}/quota-limits`, {
      method: 'DELETE',
    })
  },

  // Stats
  getStats() {
    return request<{ success: boolean; data: SystemStats }>('/api/v1/admin/stats')
  },

  // Rate limit history
  getRateLimitHistory(params: PaginationParams & { userId?: string; type?: string; startTime?: string; endTime?: string } = {}) {
    const qs = new URLSearchParams()
    if (params.page) qs.set('page', String(params.page))
    if (params.pageSize) qs.set('pageSize', String(params.pageSize))
    if (params.userId) qs.set('userId', params.userId)
    if (params.type) qs.set('type', params.type)
    if (params.startTime) qs.set('startTime', params.startTime)
    if (params.endTime) qs.set('endTime', params.endTime)
    return request<PaginatedResponse<any>>(`/api/v1/admin/rate-limit-history?${qs}`)
  },

  // Prompt Templates
  listPrompts() {
    return request<{ success: boolean; data: PromptTemplate[] }>('/api/v1/admin/prompts')
  },

  getPrompt(voiceMode: string) {
    return request<{ success: boolean; data: PromptTemplate }>(
      `/api/v1/admin/prompts/${voiceMode}`,
    )
  },

  updatePrompt(voiceMode: string, template: string) {
    return request<{ success: boolean; data: { voiceMode: string; version: string } }>(
      `/api/v1/admin/prompts/${voiceMode}`,
      { method: 'PUT', body: JSON.stringify({ template }) },
    )
  },

  resetPrompt(voiceMode: string) {
    return request<{ success: boolean }>(
      `/api/v1/admin/prompts/${voiceMode}/reset`,
      { method: 'POST' },
    )
  },

  // Identities
  listIdentities() {
    return request<{ success: boolean; data: IdentityIndex[] }>('/api/v1/admin/identities')
  },

  getIdentity(id: string) {
    return request<{ success: boolean; data: Identity }>(`/api/v1/admin/identities/${id}`)
  },

  createIdentity(data: {
    id: string
    label: string
    description?: string
    corrections: CorrectionRule[]
    enabled?: boolean
    vocabularyId?: string
    hotwords?: HotwordEntry[]
  }) {
    return request<{ success: boolean; data: Identity }>('/api/v1/admin/identities', {
      method: 'POST',
      body: JSON.stringify(data),
    })
  },

  updateIdentity(
    id: string,
    data: {
      label?: string
      description?: string
      corrections?: CorrectionRule[]
      enabled?: boolean
      vocabularyId?: string
      hotwords?: HotwordEntry[]
    },
  ) {
    return request<{ success: boolean; data: Identity }>(`/api/v1/admin/identities/${id}`, {
      method: 'PUT',
      body: JSON.stringify(data),
    })
  },

  deleteIdentity(id: string) {
    return request<{ success: boolean }>(`/api/v1/admin/identities/${id}`, {
      method: 'DELETE',
    })
  },

  // App Release — Electron (pre -> latest)
  publishRelease(channel: 'beta' | 'production') {
    return request<{ success: boolean; data: { channel: string; message: string } }>(
      `/api/v1/admin/app-updates/publish?channel=${channel}`,
      { method: 'POST' },
    )
  },

  // App Release — Mac Native / Sparkle (appcast-pre -> appcast)
  publishMacNativeRelease(channel: 'beta' | 'production', options?: { criticalUpdate?: boolean }) {
    const params = new URLSearchParams({ channel })
    if (options?.criticalUpdate !== undefined) {
      params.set('criticalUpdate', String(options.criticalUpdate))
    }
    return request<{ success: boolean; data: { channel: string; isCritical?: boolean; message: string } }>(
      `/api/v1/admin/app-updates/publish-mac-native?${params}`,
      { method: 'POST' },
    )
  },
}
