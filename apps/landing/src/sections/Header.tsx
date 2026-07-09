import { defineComponent } from 'vue'
import { RouterLink } from 'vue-router'

const XisperLogo = defineComponent({
  setup() {
    return () => (
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 310 100" class="h-8 md:h-9">
        <g>
          <circle cx="50" cy="50" r="42" fill="none" stroke="#007C8B" stroke-width="6"/>
          <line x1="20.3" y1="20.3" x2="31.6" y2="31.6" stroke="#007C8B" stroke-width="6" stroke-linecap="square"/>
          <line x1="79.7" y1="20.3" x2="68.4" y2="31.6" stroke="#007C8B" stroke-width="6" stroke-linecap="square"/>
          <line x1="20.3" y1="79.7" x2="31.6" y2="68.4" stroke="#007C8B" stroke-width="6" stroke-linecap="square"/>
          <line x1="79.7" y1="79.7" x2="68.4" y2="68.4" stroke="#007C8B" stroke-width="6" stroke-linecap="square"/>
          <rect x="35" y="40.5" width="6" height="19" fill="#007C8B"/>
          <rect x="47" y="35" width="6" height="30" fill="#007C8B"/>
          <rect x="59" y="40.5" width="6" height="19" fill="#007C8B"/>
        </g>
        <text x="99" y="68" font-family="SF Pro Display, -apple-system, Helvetica Neue, Arial, sans-serif" font-size="62" font-weight="600" fill="#E8F0F4" letter-spacing="-1">isper</text>
      </svg>
    )
  },
})

export default defineComponent({
  name: 'SiteHeader',
  setup() {
    return () => (
      <header class="w-full flex items-center justify-between px-5 md:px-20 py-4 md:py-5">
        <RouterLink to="/" class="no-underline flex items-center">
          <XisperLogo />
        </RouterLink>

        <nav class="hidden md:flex items-center gap-9">
          <a href="/#roles" class="text-[15px] font-medium text-text-secondary hover:text-text-primary transition-colors">Roles</a>
          <a href="/#features" class="text-[15px] font-medium text-text-secondary hover:text-text-primary transition-colors">Features</a>
          <a href="/#how-it-works" class="text-[15px] font-medium text-text-secondary hover:text-text-primary transition-colors">How it Works</a>
        </nav>

        <div class="flex items-center gap-4 md:gap-6">
          <a
            href="https://xisper.hawkeye-xb.com/api/v1/app/mac/updates/download/production/latest"
            class="px-4 md:px-6 py-2 md:py-2.5 bg-accent text-bg-primary text-sm font-semibold rounded-lg hover:bg-accent-light transition-colors"
          >
            Download
          </a>
        </div>
      </header>
    )
  },
})
