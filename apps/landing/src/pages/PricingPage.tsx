import { defineComponent } from 'vue'
import { Check } from 'lucide-vue-next'

const PRICING_PLANS = [
  {
    name: 'Free',
    price: '$0',
    period: 'forever',
    description: 'For casual users and trying out Xisper',
    badge: '',
    features: [
      '75 minutes of speech recognition per week',
      '10,000 characters per week',
      '900 AI processing calls per day',
      'Role-based vocabulary (Developer, Lawyer, Doctor, PM)',
      'Custom hotwords and corrections',
      'Local audio storage',
      'Cross-device sync',
    ],
    cta: 'Download Free',
    ctaHref: 'https://xisper.hawkeye-xb.com/api/v1/app/mac/updates/download/production/latest',
    highlighted: false,
  },
  {
    name: 'Pro',
    price: '$9.99',
    period: 'per month',
    description: 'For professionals who rely on speech-to-text daily',
    badge: 'Popular',
    features: [
      '13.3 hours of speech recognition per week',
      '80,000 characters per week',
      '3,200 AI processing calls per day',
      'Role-based vocabulary (Developer, Lawyer, Doctor, PM)',
      'Custom hotwords and corrections',
      'Priority support',
    ],
    cta: 'Start Free Trial',
    ctaHref: '#pro',
    highlighted: true,
  },
  {
    name: 'Pro Yearly',
    price: '$79.99',
    period: 'per year',
    description: 'Same Pro features, billed annually — save 33%',
    badge: 'Best Value',
    features: [
      '13.3 hours of speech recognition per week',
      '80,000 characters per week',
      '3,200 AI processing calls per day',
      'Role-based vocabulary (Developer, Lawyer, Doctor, PM)',
      'Custom hotwords and corrections',
      'Priority support',
    ],
    cta: 'Start Free Trial',
    ctaHref: '#pro-yearly',
    highlighted: false,
  },
] as const

export default defineComponent({
  name: 'PricingPage',
  setup() {
    return () => (
      <div class="min-h-screen bg-bg-primary">
        {/* Hero */}
        <section class="flex flex-col items-center px-6 md:px-[120px] pt-16 md:pt-20 pb-12 md:pb-16 gap-4">
          <h1 class="text-4xl md:text-5xl font-extrabold text-text-primary text-center leading-tight">
            Simple, Transparent Pricing
          </h1>
          <p class="max-w-[600px] text-lg text-text-secondary text-center">
            Choose the plan that fits your workflow. Start free, upgrade when you need more.
          </p>
        </section>

        {/* Pricing Cards */}
        <section class="flex flex-col md:flex-row items-stretch justify-center gap-6 px-6 md:px-[120px] pb-20">
          {PRICING_PLANS.map((plan) => (
            <div
              key={plan.name}
              class={[
                'flex flex-col w-full md:w-[340px] p-8 rounded-2xl border transition-all',
                plan.highlighted
                  ? 'border-accent bg-bg-secondary shadow-lg scale-105'
                  : 'border-border-default bg-bg-primary',
              ].join(' ')}
            >
              {/* Plan Name */}
              <div class="flex items-center justify-between mb-2">
                <h3 class="text-xl font-bold text-text-primary">{plan.name}</h3>
                {plan.badge && (
                  <span class="px-3 py-1 bg-accent text-bg-primary text-xs font-semibold rounded-full">
                    {plan.badge}
                  </span>
                )}
              </div>

              {/* Price */}
              <div class="flex items-baseline gap-2 mb-2">
                <span class="text-5xl font-extrabold text-text-primary">{plan.price}</span>
                <span class="text-base text-text-muted">/ {plan.period}</span>
              </div>

              {/* Description */}
              <p class="text-sm text-text-secondary mb-6">{plan.description}</p>

              {/* CTA Button */}
              <a
                href={plan.ctaHref}
                class={[
                  'flex items-center justify-center w-full px-6 py-3 rounded-xl text-base font-semibold transition-colors mb-8',
                  plan.highlighted
                    ? 'bg-accent text-bg-primary hover:bg-accent-light'
                    : 'bg-bg-secondary text-text-primary border border-border-default hover:bg-bg-tertiary',
                ].join(' ')}
              >
                {plan.cta}
              </a>

              {/* Features */}
              <div class="flex flex-col gap-3">
                {plan.features.map((feature) => (
                  <div key={feature} class="flex items-start gap-3">
                    <Check size={20} class="flex-shrink-0 text-accent mt-0.5" />
                    <span class="text-sm text-text-secondary">{feature}</span>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </section>

        {/* FAQ */}
        <section class="flex flex-col items-center px-6 md:px-[120px] py-20 bg-bg-secondary">
          <h2 class="text-3xl font-bold text-text-primary mb-12">Frequently Asked Questions</h2>
          <div class="max-w-[800px] w-full flex flex-col gap-8">
            <FAQItem
              question="What happens when I reach my quota?"
              answer="When you reach your weekly speech recognition limit or daily AI processing limit, the app will notify you. You can either wait for the quota to reset (weekly on Monday at 03:00 Beijing Time for ASR, daily at 03:00 Beijing Time for AI processing) or upgrade to Pro for higher limits."
            />
            <FAQItem
              question="Can I try Pro before paying?"
              answer="Yes! We offer a free trial period for Pro users. Download the app and sign up to start your trial."
            />
            <FAQItem
              question="How is speech recognition time calculated?"
              answer="Speech recognition time is measured by the actual duration of your audio recordings. For example, if you record a 5-minute meeting, that counts as 5 minutes towards your weekly quota."
            />
            <FAQItem
              question="What are AI processing calls?"
              answer="AI processing calls are used when you apply post-processing features like summarization, formatting, or other AI-powered enhancements to your transcribed text. Each operation counts as one call."
            />
            <FAQItem
              question="Is my data stored on your servers?"
              answer="No. Your audio recordings and transcription text are stored locally on your device. We only store your account information, usage metrics, and custom vocabulary settings (hotwords and corrections) for cross-device sync."
            />
            <FAQItem
              question="Can I cancel my Pro subscription anytime?"
              answer="Yes, you can cancel your Pro subscription at any time. You'll continue to have Pro access until the end of your current billing period."
            />
          </div>
        </section>

        {/* Footer CTA */}
        <section class="flex flex-col items-center px-6 md:px-[120px] py-20 gap-6">
          <h2 class="text-3xl md:text-4xl font-bold text-text-primary text-center">
            Ready to get started?
          </h2>
          <p class="text-lg text-text-secondary text-center max-w-[600px]">
            Download Xisper for free and experience role-based speech recognition.
          </p>
          <a
            href="https://xisper.hawkeye-xb.com/api/v1/app/mac/updates/download/production/latest"
            class="px-8 py-4 bg-accent text-bg-primary rounded-xl text-base font-semibold hover:bg-accent-light transition-colors"
          >
            Download Free
          </a>
        </section>
      </div>
    )
  },
})

function FAQItem(_props: { question: string; answer: string }) {
  return (
    <div class="flex flex-col gap-3">
      <h3 class="text-lg font-semibold text-text-primary">{_props.question}</h3>
      <p class="text-base text-text-secondary leading-relaxed">{_props.answer}</p>
    </div>
  )
}
