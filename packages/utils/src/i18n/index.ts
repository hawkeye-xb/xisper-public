import { SUPPORTED_LOCALES, DEFAULT_LOCALE, type SupportedLocale, type I18nFactoryOptions } from './types'
export * from './types'

export interface I18nInstance {
  global: {
    locale: { value: string }
    mergeLocaleMessage: (locale: string, messages: Record<string, any>) => void
    setLocaleMessage: (locale: string, messages: Record<string, any>) => void
    getLocaleMessage: (locale: string) => Record<string, any>
  }
  install: (app: any, ...options: any[]) => any
}

export class I18nFactory {
  private i18n: I18nInstance
  private pathCache: Set<string>
  private storageKey: string

  constructor(i18n: I18nInstance, options?: I18nFactoryOptions) {
    this.i18n = i18n
    this.pathCache = new Set()
    this.storageKey = options?.storageKey || 'locale'
  }

  /**
   * Get locale from storage, browser settings, or default
   * Priority: storage -> browser -> default
   */
  getStoredLocale(): SupportedLocale {
    const stored = localStorage.getItem(this.storageKey) as SupportedLocale
    if (SUPPORTED_LOCALES.includes(stored)) {
      return stored
    }
    
    const browserLocale = navigator.language.toLowerCase()
    
    if (SUPPORTED_LOCALES.includes(browserLocale as SupportedLocale)) {
      return browserLocale as SupportedLocale
    }
    
    const languagePrefix = browserLocale.split(/[-_@]/)[0]
    const matchedLocale = SUPPORTED_LOCALES.find(locale => locale === languagePrefix)
    
    if (matchedLocale) {
      return matchedLocale
    }
    
    return DEFAULT_LOCALE
  }

  /**
   * Set locale message with namespace
   */
  setLocaleMessage(namespace: string, messages: Record<string, any>, locale?: SupportedLocale): void {
    if (!namespace || !messages) {
      console.warn('[i18n] setLocaleMessage: namespace and messages are required')
      return
    }

    try {
      const targetLocale = locale || this.i18n.global.locale.value as SupportedLocale
      const namespacedMessages = { [namespace]: messages }
      this.i18n.global.mergeLocaleMessage(targetLocale, namespacedMessages)
    } catch (error) {
      console.error('[i18n] setLocaleMessage error:', error)
    }
  }

  /**
   * Merge messages directly to root level
   */
  mergeToGlobalRoot(messages: Record<string, any>, locale?: SupportedLocale): void {
    if (!messages) {
      console.warn('[i18n] mergeToGlobalRoot: messages are required')
      return
    }

    try {
      const targetLocale = locale || this.i18n.global.locale.value as SupportedLocale
      this.i18n.global.mergeLocaleMessage(targetLocale, messages)
    } catch (error) {
      console.error('[i18n] mergeToGlobalRoot error:', error)
    }
  }

  /**
   * Delete locale message by namespace
   */
  deleteLocaleMessage(namespace: string, locale?: SupportedLocale): void {
    if (!namespace) {
      console.warn('[i18n] deleteLocaleMessage: namespace is required')
      return
    }

    try {
      const targetLocale = locale || this.i18n.global.locale.value as SupportedLocale
      const currentMessages = this.i18n.global.getLocaleMessage(targetLocale) || {}

      if (!(namespace in currentMessages)) {
        console.warn(`[i18n] deleteLocaleMessage: namespace '${namespace}' not found`)
        return
      }

      const updatedMessages: Record<string, any> = { ...currentMessages }
      delete updatedMessages[namespace]
      this.i18n.global.setLocaleMessage(targetLocale, updatedMessages)
    } catch (error) {
      console.error('[i18n] deleteLocaleMessage error:', error)
    }
  }

  /**
   * Check if namespace exists in locale messages
   */
  hasLocaleMessage(namespace: string, locale?: SupportedLocale): boolean {
    try {
      const targetLocale = locale || this.i18n.global.locale.value as SupportedLocale
      const currentMessages = this.i18n.global.getLocaleMessage(targetLocale) || {}
      return namespace in currentMessages
    } catch (error) {
      console.error('[i18n] hasLocaleMessage error:', error)
      return false
    }
  }

  /**
   * Get namespace message
   */
  getNamespaceMessage(namespace: string, locale?: SupportedLocale): Record<string, any> | null {
    try {
      const targetLocale = locale || this.i18n.global.locale.value as SupportedLocale
      const currentMessages = this.i18n.global.getLocaleMessage(targetLocale) || {}
      return currentMessages[namespace] || null
    } catch (error) {
      console.error('[i18n] getNamespaceMessage error:', error)
      return null
    }
  }

  /**
   * Get path cache
   */
  getPathCache(): Set<string> {
    return this.pathCache
  }

  /**
   * Add path to cache
   */
  addPath(path: string): void {
    this.pathCache.add(path)
  }

  /**
   * Check if path is cached
   */
  hasPath(path: string): boolean {
    return this.pathCache.has(path)
  }

  /**
   * Clear path cache
   */
  clearPathCache(): void {
    this.pathCache.clear()
  }

  /**
   * Delete path from cache
   */
  deletePath(path: string): boolean {
    return this.pathCache.delete(path)
  }

  /**
   * Get current locale
   */
  getCurrentLocale(): SupportedLocale {
    return this.i18n.global.locale.value as SupportedLocale
  }

  /**
   * Set current locale
   */
  setCurrentLocale(locale: SupportedLocale): void {
    this.i18n.global.locale.value = locale
  }

  /**
   * Save locale to storage
   */
  saveLocale(locale: SupportedLocale): void {
    localStorage.setItem(this.storageKey, locale)
  }
}