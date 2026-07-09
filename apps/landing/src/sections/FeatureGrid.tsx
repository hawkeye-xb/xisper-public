import { defineComponent } from 'vue'
import { ScanEye, BookOpen, ShieldCheck, Webhook } from 'lucide-vue-next'

const cards = [
  {
    icon: ScanEye,
    title: 'Context-Aware',
    desc: 'Xisper automatically reads the current app, window title, and selected text, letting AI tailor output to your writing context.',
  },
  {
    icon: BookOpen,
    title: 'Custom Hotwords',
    desc: 'Add your technical terms, names, and abbreviations. Xisper learns your vocabulary to ensure precise recognition of proper nouns.',
  },
  {
    icon: ShieldCheck,
    title: 'Privacy First',
    desc: 'Audio is processed in real-time and never stored. Your voice data always belongs to you—we never use it for training.',
  },
  {
    icon: Webhook,
    title: 'Webhook Integration',
    desc: 'Send transcription results to Notion, Slack, or any API. Connect Xisper to your workflow via webhooks.',
  },
]

export default defineComponent({
  name: 'FeatureGrid',
  setup() {
    return () => (
      <section class="flex flex-col items-center px-6 md:px-[120px] py-14 md:py-25 gap-10 md:gap-12">
        <div class="flex flex-col items-center gap-4">
          <span class="text-xs font-semibold text-accent tracking-[2px] uppercase">More Features</span>
          <h2 class="text-3xl md:text-[44px] font-bold text-text-primary text-center leading-tight">
            Built for Power Users
          </h2>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-5 md:gap-6 w-full max-w-[900px]">
          {cards.map((c) => (
            <div class="flex flex-col gap-4 p-6 md:p-8 rounded-2xl bg-bg-surface border border-border-default hover:border-accent/30 transition-colors">
              <c.icon size={28} class="text-accent" />
              <h3 class="text-lg font-semibold text-text-primary">{c.title}</h3>
              <p class="text-sm text-text-secondary leading-relaxed">{c.desc}</p>
            </div>
          ))}
        </div>
      </section>
    )
  },
})
