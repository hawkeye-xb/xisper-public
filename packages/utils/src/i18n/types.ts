export const SUPPORTED_LOCALES = ['en', 'zh', 'ja'] as const
export type SupportedLocale = typeof SUPPORTED_LOCALES[number]

export const DEFAULT_LOCALE: SupportedLocale = 'en'

export interface I18nFactoryOptions {
  locale?: SupportedLocale
  fallbackLocale?: SupportedLocale
  legacy?: boolean
  globalInjection?: boolean
  storageKey?: string
}

export const defaultI18nOptions = {
  locale: DEFAULT_LOCALE,
  fallbackLocale: DEFAULT_LOCALE,
  legacy: false,
  globalInjection: true,
  storageKey: 'locale',
} as const