/**
 * Admin panel configuration
 * Beta: xisper-dev.hawkeye-xb.com
 * Production: xisper.hawkeye-xb.com
 */

const mode = import.meta.env.MODE || 'beta'

const configs = {
  beta: {
    apiBaseUrl: 'https://xisper-dev.hawkeye-xb.com',
  },
  production: {
    apiBaseUrl: 'https://xisper.hawkeye-xb.com',
  },
}

const resolved = configs[mode as keyof typeof configs] || configs.beta

export const config = {
  apiBaseUrl: import.meta.env.VITE_API_BASE_URL || resolved.apiBaseUrl,
}
