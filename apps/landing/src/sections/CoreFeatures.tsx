import { defineComponent } from 'vue'
import { Mic, Sparkles, Globe, Users } from 'lucide-vue-next'
import type { Component } from 'vue'

interface Feature {
  icon: Component
  tag: string
  title: string
  desc: string
  details: string[]
  reverse: boolean
  image?: string
}

const features: Feature[] = [
  {
    icon: Users,
    tag: 'Role Vocabulary',
    title: 'Your Profession,\nYour Dictionary',
    desc: 'Different industries have different terminology. Xisper comes with vocabularies for developers, lawyers, doctors, product managers, and more—switch with one tap to load the corresponding hotwords and correction rules, so proper nouns are never mistaken for homophones.',
    details: ['One-tap role switching', 'Custom hotwords & corrections', 'Precise proper noun recognition'],
    reverse: false,
    image: '/feature-roles.png',
  },
  {
    icon: Mic,
    tag: 'Voice Dictation',
    title: 'Speak Naturally,\nTranscribe Accurately',
    desc: 'Press Fn to start speaking, and Xisper transcribes your voice in real-time with sub-second latency. Release the key, and text is automatically inserted at the cursor—works in any app.',
    details: ['Real-time streaming ASR', 'Automatic filler word removal', 'Smart punctuation & formatting'],
    reverse: true,
    image: '/feature-dictation.png',
  },
  {
    icon: Sparkles,
    tag: 'AI Polish',
    title: 'From Spoken to\nProfessional Text',
    desc: 'After each transcription, AI automatically polishes: fixes grammar, refines expressions, adjusts formatting. You speak casually, output is professional.',
    details: ['Automatic grammar correction', 'Casual to formal conversion', 'Preserves meaning while refining'],
    reverse: false,
    image: '/feature-polish.png',
  },
  {
    icon: Globe,
    tag: 'Universal',
    title: 'Everywhere\nYou Write',
    desc: "Xisper isn't a standalone editor—it's a system-level tool. Whether you're composing emails, editing documents, chatting, or writing code comments, press Fn to dictate.",
    details: ['Works in all macOS apps', 'Reads context automatically', 'No window switching needed'],
    reverse: true,
  },
]

// Real app icons for the "Universal" feature
const appIcons = [
  { name: 'Cursor', src: '/app-icons/cursor.png' },
  { name: 'Chrome', src: '/app-icons/chrome.png' },
  { name: 'WeChat', src: '/app-icons/wechat.png' },
  { name: 'Lark', src: '/app-icons/feishu.png' },
  { name: 'Mail', src: '/app-icons/mail.png' },
  { name: 'Notes', src: '/app-icons/notes.png' },
  { name: 'WPS', src: '/app-icons/wps.png' },
  { name: 'Xcode', src: '/app-icons/xcode.png' },
  { name: 'Figma', src: '/app-icons/figma.png' },
  { name: 'iTerm', src: '/app-icons/iterm.png' },
  { name: 'Messages', src: '/app-icons/messages.png' },
  { name: 'Terminal', src: '/app-icons/terminal.png' },
  { name: 'Docker', src: '/app-icons/docker.png' },
  { name: 'OBS', src: '/app-icons/obs.png' },
  { name: 'Music', src: '/app-icons/music.png' },
  { name: 'Preview', src: '/app-icons/preview.png' },
]

const AppIconWall = defineComponent({
  name: 'AppIconWall',
  setup() {
    return () => (
      <div class="w-full md:w-1/2 aspect-[4/3] rounded-2xl bg-bg-surface border border-border-default flex flex-col items-center justify-center p-6 md:p-8">
        <div class="grid grid-cols-4 gap-4 md:gap-5">
          {appIcons.map((app) => (
            <div class="group flex flex-col items-center gap-1.5">
              <div class="w-12 h-12 md:w-14 md:h-14 rounded-[14px] overflow-hidden transition-transform group-hover:scale-110 shadow-lg shadow-black/20">
                <img src={app.src} alt={app.name} class="w-full h-full object-cover" />
              </div>
              <span class="text-[10px] md:text-[11px] text-text-muted text-center leading-tight">{app.name}</span>
            </div>
          ))}
        </div>
      </div>
    )
  },
})

export default defineComponent({
  name: 'CoreFeatures',
  setup() {
    return () => (
      <section id="features" class="flex flex-col items-center px-6 md:px-[120px] py-14 md:py-25 gap-12 md:gap-20">
        {/* Header */}
        <div class="flex flex-col items-center gap-4 max-w-[700px]">
          <span class="text-xs font-semibold text-accent tracking-[2px] uppercase">Core Features</span>
          <h2 class="text-3xl md:text-[44px] font-bold text-text-primary text-center leading-tight">
            Voice Input Built for Professionals
          </h2>
          <p class="text-base md:text-lg text-text-secondary text-center max-w-[600px]">
            From role vocabularies to intelligent polish, Xisper lets professionals in every field write accurately with their voice.
          </p>
        </div>

        {/* Feature Rows */}
        {features.map((f) => (
          <div class={['flex flex-col md:flex-row items-center gap-8 md:gap-15 w-full', f.reverse ? 'md:flex-row-reverse' : '']}>
            {/* Text */}
            <div class="flex flex-col gap-4 md:gap-6 w-full md:w-1/2 shrink-0">
              <span class="self-start px-3.5 py-1.5 rounded-md bg-accent-bg text-[13px] font-semibold text-accent">
                {f.tag}
              </span>
              <h3 class="text-2xl md:text-[32px] font-bold text-text-primary leading-[1.3] whitespace-pre-line">
                {f.title}
              </h3>
              <p class="text-base text-text-secondary leading-[1.7]">{f.desc}</p>
              <ul class="flex flex-col gap-2 mt-1">
                {f.details.map((d) => (
                  <li class="flex items-center gap-2.5 text-sm text-text-secondary">
                    <span class="w-1.5 h-1.5 rounded-full bg-accent shrink-0" />
                    {d}
                  </li>
                ))}
              </ul>
            </div>

            {/* Visual */}
            {f.image ? (
              <div class="w-full md:w-1/2 aspect-[4/3] rounded-2xl bg-bg-surface border border-border-default flex items-center justify-center overflow-hidden">
                <img src={f.image} alt={f.tag} class="w-full h-full object-cover" />
              </div>
            ) : (
              <AppIconWall />
            )}
          </div>
        ))}
      </section>
    )
  },
})
