export type ThemeMode = 'dark' | 'light' | 'system'
type ResolvedTheme = 'dark' | 'light'

/**
 * Get the system's preferred color scheme
 */
const getSystemTheme = (): ResolvedTheme => {
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

/**
 * Resolve theme mode to actual theme
 * - 'system' -> resolves to system preference
 * - 'dark'/'light' -> returns as is
 */
const resolveTheme = (themeMode: ThemeMode): ResolvedTheme => {
  if (themeMode === 'system') {
    return getSystemTheme()
  }
  return themeMode as ResolvedTheme
}

/**
 * Get current theme mode from localStorage or default
 */
export const getThemeMode = (): ThemeMode => {
  const savedTheme = localStorage.getItem('data-theme') as ThemeMode
  return savedTheme || 'dark' // Default to dark
}

/**
 * Get resolved theme (actual dark/light value)
 */
export const getTheme = (): ResolvedTheme => {
  const themeMode = getThemeMode()
  return resolveTheme(themeMode)
}

/**
 * Set theme mode and apply to document
 */
export const setTheme = (themeMode: ThemeMode) => {
  // Save the theme mode preference
  localStorage.setItem('data-theme', themeMode)
  
  // Resolve and apply the actual theme
  const resolvedTheme = resolveTheme(themeMode)
  document.documentElement.setAttribute('data-theme', resolvedTheme)
  
  return { themeMode, resolvedTheme }
}

/**
 * Initialize theme on app startup
 */
export const initTheme = () => {
  const themeMode = getThemeMode()
  const resolvedTheme = resolveTheme(themeMode)
  document.documentElement.setAttribute('data-theme', resolvedTheme)
  
  // Listen for system theme changes when in system mode
  const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)')
  const handleSystemThemeChange = () => {
    if (getThemeMode() === 'system') {
      const newResolvedTheme = getSystemTheme()
      document.documentElement.setAttribute('data-theme', newResolvedTheme)
    }
  }
  
  mediaQuery.addEventListener('change', handleSystemThemeChange)
  
  return { themeMode, resolvedTheme }
}
