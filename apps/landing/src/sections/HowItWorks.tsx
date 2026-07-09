import { defineComponent } from 'vue'
import { Keyboard, Mic, TextCursorInput } from 'lucide-vue-next'

const steps = [
  {
    num: '1',
    icon: Keyboard,
    title: 'Press Fn',
    desc: 'Press the Fn key to activate Xisper. A recording indicator appears on screen, ready to go.',
  },
  {
    num: '2',
    icon: Mic,
    title: 'Speak Naturally',
    desc: 'Speak at normal pace. Xisper transcribes in real-time as AI simultaneously polishes your expression.',
  },
  {
    num: '3',
    icon: TextCursorInput,
    title: 'Text Appears',
    desc: 'Press Fn again to stop recording. The polished text is automatically inserted at the cursor. Done.',
  },
]

export default defineComponent({
  name: 'HowItWorks',
  setup() {
    return () => (
      <section id="how-it-works" class="flex flex-col items-center px-6 md:px-[120px] py-14 md:py-25 gap-10 md:gap-16 bg-bg-elevated">
        <div class="flex flex-col items-center gap-4">
          <span class="text-xs font-semibold text-accent tracking-[2px] uppercase">How It Works</span>
          <h2 class="text-3xl md:text-[44px] font-bold text-text-primary text-center leading-tight">
            Three Steps, Three Seconds
          </h2>
          <p class="text-base md:text-lg text-text-secondary text-center max-w-[500px]">
            No complex setup, no learning curve.
          </p>
        </div>

        <div class="flex flex-col md:flex-row w-full gap-6 md:gap-8">
          {steps.map((s) => (
            <div class="flex-1 flex flex-col items-center gap-4 md:gap-5 p-6 md:p-10 rounded-2xl bg-bg-surface border border-border-default">
              <div class="w-12 h-12 rounded-full bg-accent flex items-center justify-center">
                <span class="text-xl font-bold text-bg-primary">{s.num}</span>
              </div>
              <s.icon size={32} class="text-accent" />
              <h3 class="text-xl font-semibold text-text-primary">{s.title}</h3>
              <p class="text-[15px] text-text-secondary text-center leading-relaxed">{s.desc}</p>
            </div>
          ))}
        </div>
      </section>
    )
  },
})
