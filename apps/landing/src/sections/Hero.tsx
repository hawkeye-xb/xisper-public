import { defineComponent } from 'vue'
import { Download } from 'lucide-vue-next'

export default defineComponent({
  name: 'HeroSection',
  setup() {
    return () => (
      <section class="flex flex-col items-center px-6 md:px-[120px] pt-16 md:pt-28 pb-12 md:pb-20 gap-6 md:gap-8 relative overflow-hidden">
        {/* Subtle radial glow */}
        <div
          class="absolute top-0 left-1/2 -translate-x-1/2 w-[800px] h-[600px] pointer-events-none"
          style={{ background: 'radial-gradient(ellipse at center, rgba(0,124,139,0.08) 0%, transparent 70%)' }}
        />

        {/* App Icon */}
        <img src="/xisper-icon.png" alt="Xisper" class="w-20 h-20 md:w-24 md:h-24 relative z-10" />

        {/* Badge */}
        <div class="flex items-center gap-2 px-5 py-2 rounded-full border border-border-default relative z-10">
          <span class="w-2 h-2 rounded-full bg-accent animate-pulse" />
          <span class="text-[13px] font-medium text-text-secondary">Voice Dictation for macOS</span>
        </div>

        {/* Headline */}
        <h1 class="text-5xl md:text-[88px] font-extrabold text-text-primary text-center leading-tight tracking-tight relative z-10">
          Press Fn, Start Speaking
        </h1>

        {/* Subheadline */}
        <p class="max-w-[680px] text-base md:text-xl text-text-secondary text-center leading-relaxed relative z-10">
          Switch roles, switch vocabulary. Developer, Lawyer, Doctor, Product Manager—
          <br />
          Xisper loads role-specific hotwords and correction rules for accurate transcription of every domain's terminology.
        </p>

        {/* CTA */}
        <div class="flex flex-col sm:flex-row items-center gap-3 sm:gap-4 w-full sm:w-auto relative z-10">
          <a
            href="https://xisper.hawkeye-xb.com/api/v1/app/mac/updates/download/production/latest"
            class="flex items-center justify-center gap-2.5 w-full sm:w-auto px-8 py-4 bg-accent text-bg-primary rounded-xl text-base font-semibold hover:bg-accent-light transition-colors"
          >
            <Download size={20} />
            Download for Mac
          </a>
        </div>
        <span class="text-[13px] text-text-muted relative z-10">Native Swift App · Only 2.3 MB · macOS 13+</span>
      </section>
    )
  },
})
