import { defineComponent } from 'vue'

const LAST_UPDATED = 'March 23, 2026'
const CONTACT_EMAIL = 'support@hawkeye-xb.com'

export default defineComponent({
  name: 'PrivacyPolicy',
  setup() {
    return () => (
      <article class="max-w-[720px] mx-auto px-6 py-20">
        <h1 class="text-4xl font-bold text-text-primary mb-2">Privacy Policy</h1>
        <p class="text-sm text-text-muted mb-12">Last Updated: {LAST_UPDATED}</p>

        <div class="flex flex-col gap-10 text-[15px] leading-relaxed text-text-secondary">
          <p>
            Xisper ("we", "us", "our") is an AI-powered speech-to-text desktop application.
            We are committed to protecting your privacy. This Privacy Policy explains how we
            handle your information when you use Xisper.
          </p>

          {/* 1 */}
          <Section title="1. Information We Collect">
            <Subsection title="Account Information">
              <p>
                When you sign in via OAuth 2.0, we collect basic account information
                (such as your email address) solely for authentication and API access
                control purposes.
              </p>
            </Subsection>
            <Subsection title="Usage Metrics">
              <p>
                We collect minimal usage metrics (e.g., transcription character counts,
                request frequency) to enforce fair usage limits and prevent API abuse.
                These metrics are aggregated and do not contain any of your audio or
                text content.
              </p>
            </Subsection>
            <Subsection title="Hotwords and Role Vocabulary Data">
              <p>
                When you use the role-based vocabulary feature (e.g., Developer, Lawyer,
                Doctor, Product Manager), your custom hotwords, correction rules, and
                selected role preferences are stored on our servers and associated with
                your account. This allows your vocabulary settings to sync across devices
                and persist across sessions.
              </p>
              <p class="mt-2">
                This data includes: role selection, custom hotword entries, and correction
                word pairs you configure. It does not include any audio recordings or
                transcription content.
              </p>
            </Subsection>
          </Section>

          {/* 2 */}
          <Section title="2. Information We Do NOT Collect">
            <Subsection title="Audio Data">
              <p>
                Your audio recordings are processed entirely on your device and streamed
                directly to our speech recognition (ASR) service via our API relay.
                We do not store, retain, or access your original audio files at any point.
                Audio data is processed in real-time and discarded immediately after
                transcription.
              </p>
            </Subsection>
            <Subsection title="Transcription Content">
              <p>
                The text output from speech recognition is returned directly to your device.
                We do not store, log, or retain any transcription results on our servers.
              </p>
            </Subsection>
            <Subsection title="Post-Processing Data">
              <p>
                When you use AI-powered post-processing features (such as summarization
                or formatting), the processed results are returned directly to your device.
                We do not retain any post-processing inputs or outputs on our servers.
              </p>
            </Subsection>
          </Section>

          {/* 3 */}
          <Section title="3. Data Storage">
            <Subsection title="Local Storage">
              <p>
                Audio recordings, transcription text, and post-processed content are
                stored exclusively on your local device. We have no access to this
                locally stored data.
              </p>
            </Subsection>
            <Subsection title="Cloud Storage">
              <p>
                Your hotwords, correction rules, and role vocabulary preferences are
                stored on our servers to enable cross-device sync and data persistence.
                You may delete your custom vocabulary data at any time through the
                application settings.
              </p>
            </Subsection>
          </Section>

          {/* 4 */}
          <Section title="4. How We Use Your Information">
            <p>We use the limited information we collect to:</p>
            <ul class="list-disc pl-5 mt-2 flex flex-col gap-1.5">
              <li>Authenticate your identity and manage your account</li>
              <li>Provide and maintain the Xisper service</li>
              <li>Enforce usage limits to ensure fair access for all users</li>
              <li>Prevent abuse and unauthorized use of our API</li>
            </ul>
          </Section>

          {/* 5 */}
          <Section title="5. Data Sharing">
            <p>
              We do not sell, trade, or share your personal information with third
              parties, except:
            </p>
            <ul class="list-disc pl-5 mt-2 flex flex-col gap-1.5">
              <li>
                <strong class="text-text-primary">ASR Service Providers</strong>: Your
                audio is streamed to third-party speech recognition services for real-time
                transcription. These providers process the audio in real-time and do not
                retain it.
              </li>
              <li>
                <strong class="text-text-primary">AI Processing Services</strong>: When you
                use AI-powered post-processing features (such as summarization and formatting),
                your text is sent to Alibaba Cloud Qwen services. These services include
                built-in content safety mechanisms that automatically filter inappropriate
                content (sensitive keywords, NSFW content, PII, etc.). The AI service provider
                processes your text in real-time and does not retain it.
              </li>
              <li>
                <strong class="text-text-primary">Legal Requirements</strong>: We may
                disclose information if required by law.
              </li>
            </ul>
          </Section>

          {/* 6 */}
          <Section title="6. Data Security">
            <p>
              We implement reasonable security measures to protect the limited data we
              handle. All API communications are encrypted via HTTPS/TLS.
            </p>
          </Section>

          {/* 7 */}
          <Section title="7. Data Retention and Deletion">
            <ul class="list-disc pl-5 flex flex-col gap-1.5">
              <li>
                <strong class="text-text-primary">Account data</strong>: Retained while
                your account is active. You may request account deletion by contacting us.
              </li>
              <li>
                <strong class="text-text-primary">Usage metrics</strong>: Retained in
                aggregated form for service operation.
              </li>
              <li>
                <strong class="text-text-primary">Audio, transcription, and post-processing data</strong>:
                Never stored on our servers.
              </li>
              <li>
                <strong class="text-text-primary">Hotwords and vocabulary data</strong>:
                Retained while your account is active. Deleted upon account deletion or
                when you manually remove them in the application.
              </li>
            </ul>
          </Section>

          {/* 8 */}
          <Section title="8. Children's Privacy">
            <p>
              Xisper is not intended for use by children under the age of 13. We do not
              knowingly collect personal information from children.
            </p>
          </Section>

          {/* 9 */}
          <Section title="9. Changes to This Policy">
            <p>
              We may update this Privacy Policy from time to time. We will notify you of
              significant changes by posting the updated policy on this page with a new
              "Last Updated" date.
            </p>
          </Section>

          {/* 10 */}
          <Section title="10. Contact Us">
            <p>
              If you have questions about this Privacy Policy, please contact us at{' '}
              <a href={`mailto:${CONTACT_EMAIL}`} class="text-accent hover:text-accent-light transition-colors">
                {CONTACT_EMAIL}
              </a>.
            </p>
          </Section>
        </div>
      </article>
    )
  },
})

function Section(_props: { title: string }, { slots }: { slots: any }) {
  return (
    <section>
      <h2 class="text-xl font-semibold text-text-primary mb-3">{_props.title}</h2>
      {slots.default?.()}
    </section>
  )
}

function Subsection(_props: { title: string }, { slots }: { slots: any }) {
  return (
    <div class="mt-3">
      <h3 class="text-base font-medium text-text-primary mb-1.5">{_props.title}</h3>
      {slots.default?.()}
    </div>
  )
}
