import { defineComponent } from 'vue'
import { Zap, Sparkles, AppWindow, ShieldCheck } from 'lucide-vue-next'

const items = [
  { icon: Zap, label: 'Real-time Streaming ASR' },
  { icon: Sparkles, label: 'AI-Powered Polish' },
  { icon: AppWindow, label: 'Works in Any App' },
  { icon: ShieldCheck, label: 'Privacy First' },
]

export default defineComponent({
  name: 'HighlightsBar',
  setup() {
    return () => (
      <section class="w-full grid grid-cols-2 md:flex md:items-center md:justify-between px-6 md:px-[120px] py-6 md:py-10 gap-4 md:gap-0 bg-bg-highlight border-y border-border-subtle">
        {items.map((item, i) => (
          <>
            <div class="flex items-center gap-3">
              <item.icon size={22} class="text-accent" />
              <span class="text-[13px] md:text-[15px] font-medium text-text-primary">{item.label}</span>
            </div>
            {i < items.length - 1 && <div class="hidden md:block w-px h-6 bg-border-default" />}
          </>
        ))}
      </section>
    )
  },
})
