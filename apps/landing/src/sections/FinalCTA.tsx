import { defineComponent } from 'vue'
import { Download } from 'lucide-vue-next'

export default defineComponent({
  name: 'FinalCTA',
  setup() {
    return () => (
      <section
        id="download"
        class="flex flex-col items-center px-6 md:px-[120px] py-16 md:py-30 gap-6 md:gap-8"
        style={{ background: 'linear-gradient(180deg, rgba(0,124,139,0.1) 0%, transparent 100%)' }}
      >
        <h2 class="text-3xl md:text-5xl font-bold text-text-primary text-center">
          Ready to Write with Your Voice?
        </h2>
        <p class="max-w-[560px] text-base md:text-lg text-text-secondary text-center leading-relaxed">
          Download Xisper for free and start dictating in seconds.
          {'\n'}No credit card, no complex setup—just press Fn to begin.
        </p>
        <a
          href="https://xisper.hawkeye-xb.com/api/v1/app/mac/updates/download/production/latest"
          class="flex items-center justify-center gap-2.5 w-full sm:w-auto px-8 md:px-10 py-4 md:py-[18px] bg-accent text-bg-primary rounded-xl text-base md:text-[17px] font-semibold hover:bg-accent-light transition-colors"
        >
          <Download size={20} />
          Download for Mac
        </a>
        <span class="text-[13px] text-text-muted">Native Swift App · Only 2.3 MB · macOS 13+</span>
      </section>
    )
  },
})
