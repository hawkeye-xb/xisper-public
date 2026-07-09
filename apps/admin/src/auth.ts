/**
 * Independent admin authentication (no Logto).
 * Stores JWT in localStorage, provides reactive auth state.
 */

import { ref, computed } from 'vue'
import { config } from './config'

const STORAGE_KEY_TOKEN = 'admin_token'
const STORAGE_KEY_USERNAME = 'admin_username'

const token = ref<string | null>(localStorage.getItem(STORAGE_KEY_TOKEN))
const username = ref<string | null>(localStorage.getItem(STORAGE_KEY_USERNAME))

function isTokenExpired(t: string): boolean {
  try {
    const payload = JSON.parse(atob(t.split('.')[1]))
    return payload.exp * 1000 < Date.now()
  } catch {
    return true
  }
}

export const isAuthenticated = computed(() => {
  return !!token.value && !isTokenExpired(token.value)
})

export function getToken(): string | null {
  if (token.value && isTokenExpired(token.value)) {
    logout()
    return null
  }
  return token.value
}

export function getUsername(): string | null {
  return username.value
}

export async function login(user: string, password: string): Promise<void> {
  const res = await fetch(`${config.apiBaseUrl}/api/v1/admin-auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: user, password }),
  })

  const data = await res.json()

  if (!res.ok || !data.success) {
    throw new Error(data.error || 'Login failed')
  }

  token.value = data.token
  username.value = data.username
  localStorage.setItem(STORAGE_KEY_TOKEN, data.token)
  localStorage.setItem(STORAGE_KEY_USERNAME, data.username)
}

export function logout() {
  token.value = null
  username.value = null
  localStorage.removeItem(STORAGE_KEY_TOKEN)
  localStorage.removeItem(STORAGE_KEY_USERNAME)
}
