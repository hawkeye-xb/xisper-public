import { defineComponent, ref } from 'vue'
import { Code, Scale, Stethoscope, BarChart3, PenTool, Briefcase } from 'lucide-vue-next'
import type { Component } from 'vue'

interface Role {
  id: string
  icon: Component
  name: string
  desc: string
  hotwords: string[]
  example: { without: string; with: string }
}

const roles: Role[] = [
  {
    id: 'developer',
    icon: Code,
    name: 'Developer',
    desc: 'Technical terms with mixed case, unrecognized abbreviations—load the developer vocabulary for accurate output.',
    hotwords: ['Kubernetes', 'TypeScript', 'WebSocket', 'OAuth', 'PostgreSQL', 'CI/CD', 'Nginx', 'Redis'],
    example: {
      without: 'we need to scale the kubernetes pod then check postgresql connection pool and nginx reverse proxy config',
      with: 'We need to scale the Kubernetes Pod, then check PostgreSQL connection pool and Nginx reverse proxy config.',
    },
  },
  {
    id: 'lawyer',
    icon: Scale,
    name: 'Lawyer',
    desc: 'Legal terminology prone to homophone confusion and improper punctuation—load the legal vocabulary for precise terms and proper phrasing.',
    hotwords: ['Good Faith Acquisition', 'Force Majeure', 'Statute of Limitations', 'Contractual Negligence', 'Jurisdiction Challenge', 'Res Judicata'],
    example: {
      without: 'defendant claims force major defense but under contractual negligence principle failure to notify during statute of limitation does not constitute exemption',
      with: 'Defendant claims force majeure defense, but under contractual negligence principle, failure to notify during statute of limitations does not constitute exemption.',
    },
  },
  {
    id: 'doctor',
    icon: Stethoscope,
    name: 'Doctor',
    desc: 'Drug names and medical test terms easily mistaken for common homophones—load the medical vocabulary for accurate terminology.',
    hotwords: ['Amoxicillin', 'Omeprazole', 'MRI', 'CT Scan', 'Oxygen Saturation', 'Creatinine Clearance'],
    example: {
      without: 'patient has low creatine clearance recommend stopping amoxilin switch to omeprasole oral and repeat mri',
      with: 'Patient has low creatinine clearance, recommend stopping Amoxicillin, switch to Omeprazole oral, and repeat MRI.',
    },
  },
  {
    id: 'pm',
    icon: BarChart3,
    name: 'Product Manager',
    desc: 'English abbreviations easily converted to lowercase or misspelled, inconsistent number formats—load the product vocabulary for standardized abbreviations and formatting.',
    hotwords: ['DAU', 'MAU', 'OKR', 'GMV', 'A/B Testing', 'Conversion Funnel', 'MVP', 'ROI'],
    example: {
      without: 'this quarter okr is to increase dau by twenty percent need to ship an mvp first do an ab test see roi change',
      with: 'This quarter OKR is to increase DAU by 20%, need to ship an MVP first, do an A/B test, see ROI change.',
    },
  },
  {
    id: 'writer',
    icon: PenTool,
    name: 'Writer',
    desc: 'Literary terminology easily replaced with homophones—load the writing vocabulary for precise terms.',
    hotwords: ['Montage', 'Stream of Consciousness', 'Intertextuality', 'Metanarrative', 'Defamiliarization', 'Deconstruction'],
    example: {
      without: 'this passage uses montage technique with stream of consciousness narrative needs intertextual reference to enhance defamiliarization effect',
      with: 'This passage uses montage technique with stream of consciousness narrative, needs intertextual reference to enhance defamiliarization effect.',
    },
  },
  {
    id: 'finance',
    icon: Briefcase,
    name: 'Finance Professional',
    desc: 'Financial abbreviations and terminology prone to recognition errors—load the finance vocabulary for accurate terms and formatting.',
    hotwords: ['EBITDA', 'PE Ratio', 'Risk Exposure', 'Hedge Fund', 'Sharpe Ratio', 'Asset Securitization'],
    example: {
      without: 'currently pe ratio is high recommend monitoring ebitda and sharp ratio to assess hedge fund risk exposure',
      with: 'Currently PE ratio is high, recommend monitoring EBITDA and Sharpe ratio to assess hedge fund risk exposure.',
    },
  },
]

export default defineComponent({
  name: 'RoleShowcase',
  setup() {
    const activeRole = ref('developer')

    const current = () => roles.find((r) => r.id === activeRole.value)!

    return () => (
      <section id="roles" class="flex flex-col items-center px-6 md:px-[120px] py-14 md:py-25 gap-10 md:gap-14 bg-bg-elevated">
        {/* Header */}
        <div class="flex flex-col items-center gap-4 max-w-[700px]">
          <span class="text-xs font-semibold text-accent tracking-[2px] uppercase">Role Vocabulary</span>
          <h2 class="text-3xl md:text-[44px] font-bold text-text-primary text-center leading-tight">
            Switch Roles, Switch Vocabulary
          </h2>
          <p class="text-base md:text-lg text-text-secondary text-center max-w-[600px]">
            Every profession has its own language. Xisper comes with built-in vocabularies for multiple roles—switch with one tap to dramatically improve recognition accuracy for technical terms, industry abbreviations, and proper nouns.
          </p>
        </div>

        {/* Role Tabs */}
        <div class="flex flex-wrap justify-center gap-2 md:gap-3">
          {roles.map((r) => (
            <button
              onClick={() => { activeRole.value = r.id }}
              class={[
                'flex items-center gap-2 px-4 py-2.5 rounded-xl text-sm font-medium transition-all cursor-pointer border',
                activeRole.value === r.id
                  ? 'bg-accent text-bg-primary border-accent'
                  : 'bg-bg-surface text-text-secondary border-border-default hover:border-accent/40',
              ]}
            >
              <r.icon size={16} />
              {r.name}
            </button>
          ))}
        </div>

        {/* Active Role Detail */}
        <div class="w-full max-w-[900px] flex flex-col gap-6">
          {/* Description */}
          <p class="text-base text-text-secondary text-center">{current().desc}</p>

          {/* Hotwords */}
          <div class="flex flex-col gap-3 p-6 md:p-8 rounded-2xl bg-bg-surface border border-border-default">
            <span class="text-xs font-semibold text-accent tracking-[1px] uppercase">Sample Hotwords</span>
            <div class="flex flex-wrap gap-2">
              {current().hotwords.map((w) => (
                <span class="px-3 py-1.5 rounded-lg bg-accent-bg text-sm font-medium text-accent border border-accent/20">
                  {w}
                </span>
              ))}
            </div>
          </div>

          {/* Before/After Example */}
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div class="flex flex-col gap-3 p-6 rounded-2xl bg-bg-surface border border-red-500/20">
              <div class="flex items-center gap-2">
                <span class="w-2 h-2 rounded-full bg-red-400" />
                <span class="text-xs font-semibold text-red-400 tracking-[1px] uppercase">Without Hotwords</span>
              </div>
              <p class="text-sm text-text-muted leading-relaxed">{current().example.without}</p>
            </div>
            <div class="flex flex-col gap-3 p-6 rounded-2xl bg-bg-surface border border-accent/30">
              <div class="flex items-center gap-2">
                <span class="w-2 h-2 rounded-full bg-accent" />
                <span class="text-xs font-semibold text-accent tracking-[1px] uppercase">With Role Vocabulary</span>
              </div>
              <p class="text-sm text-text-primary leading-relaxed">{current().example.with}</p>
            </div>
          </div>
        </div>
      </section>
    )
  },
})
