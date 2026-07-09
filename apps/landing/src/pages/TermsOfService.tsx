import { defineComponent } from 'vue'

const LAST_UPDATED = 'March 23, 2026'
const CONTACT_EMAIL = 'support@hawkeye-xb.com'

export default defineComponent({
  name: 'TermsOfService',
  setup() {
    return () => (
      <article class="max-w-[720px] mx-auto px-6 py-20">
        <h1 class="text-4xl font-bold text-text-primary mb-2">Terms of Service</h1>
        <p class="text-sm text-text-muted mb-12">Last Updated: {LAST_UPDATED}</p>

        <div class="flex flex-col gap-10 text-[15px] leading-relaxed text-text-secondary">
          <p>
            Welcome to Xisper. These Terms of Service ("Terms") govern your use of the
            Xisper application and related services ("Service") operated by hawkeye-xb
            ("we", "us", or "our"). By using Xisper, you agree to these Terms. If you do not agree,
            please do not use the Service.
          </p>

          {/* 1 */}
          <Section title="1. Service Description">
            <p>
              Xisper is an AI-powered desktop application that provides real-time
              speech-to-text transcription and AI-assisted post-processing. The Service
              processes audio locally on your device and uses cloud-based APIs for speech
              recognition and text processing.
            </p>
          </Section>

          {/* 2 */}
          <Section title="2. Account">
            <p>
              You must sign in with a valid account to use Xisper. You are responsible
              for maintaining the security of your account credentials and for all
              activities under your account.
            </p>
          </Section>

          {/* 3 */}
          <Section title="3. Acceptable Use">
            <p>You agree not to:</p>
            <ul class="list-disc pl-5 mt-2 flex flex-col gap-1.5">
              <li>Use the Service for any illegal or unauthorized purpose</li>
              <li>Attempt to bypass usage limits or rate controls</li>
              <li>Reverse engineer, decompile, or disassemble the Service</li>
              <li>Use automated tools to abuse or overload the Service</li>
              <li>Share your account credentials with others</li>
              <li>Interfere with or disrupt the Service's infrastructure</li>
            </ul>
          </Section>

          {/* 4 */}
          <Section title="4. Usage Limits">
            <p>
              Xisper may impose usage limits (such as transcription duration or character
              counts) to ensure fair access. These limits may change at our discretion.
              We will notify you when you approach or reach your limits.
            </p>
          </Section>

          {/* 5 */}
          <Section title="5. Intellectual Property">
            <p>
              The Xisper application, including its design, code, and branding, is owned
              by us and protected by intellectual property laws. Your transcription content
              and data remain yours — we claim no ownership over your content.
            </p>
          </Section>

          {/* 6 */}
          <Section title="6. Your Content">
            <p>
              You retain full ownership of all audio, transcription text, and processed
              content generated through the Service. Audio and transcription content is
              stored locally on your device and is not retained on our servers.
            </p>
            <p class="mt-2">
              Your custom hotwords, correction rules, and role vocabulary preferences
              are stored on our servers to provide cross-device sync and data
              persistence. You may delete this data at any time through the application
              settings.
            </p>
          </Section>

          {/* 7 */}
          <Section title="7. Third-Party Services">
            <p>
              Xisper integrates with third-party services (such as speech recognition
              providers). Your use of these integrated services is subject to their
              respective terms and policies.
            </p>
          </Section>

          {/* 8 */}
          <Section title="8. Disclaimer of Warranties">
            <p>
              The Service is provided "AS IS" and "AS AVAILABLE" without warranties of
              any kind, express or implied. We do not guarantee that:
            </p>
            <ul class="list-disc pl-5 mt-2 flex flex-col gap-1.5">
              <li>The Service will be uninterrupted or error-free</li>
              <li>Transcription results will be 100% accurate</li>
              <li>The Service will meet your specific requirements</li>
            </ul>
          </Section>

          {/* 9 */}
          <Section title="9. Limitation of Liability">
            <p>
              To the maximum extent permitted by law, we shall not be liable for any
              indirect, incidental, special, consequential, or punitive damages arising
              from your use of the Service, including but not limited to loss of data,
              revenue, or profits.
            </p>
          </Section>

          {/* 10 */}
          <Section title="10. Changes to Terms">
            <p>
              We reserve the right to modify these Terms at any time. We will notify you
              of significant changes by posting the updated Terms on this page. Your
              continued use of the Service after changes constitutes acceptance of the
              modified Terms.
            </p>
          </Section>

          {/* 11 */}
          <Section title="11. Termination">
            <p>
              We may suspend or terminate your access to the Service at any time, with
              or without cause. Upon termination, your right to use the Service ceases
              immediately.
            </p>
          </Section>

          {/* 12 */}
          <Section title="12. Governing Law">
            <p>
              These Terms shall be governed by and construed in accordance with applicable
              laws, without regard to conflict of law principles.
            </p>
          </Section>

          {/* 13 */}
          <Section title="13. Contact Us">
            <p>
              If you have questions about these Terms, please contact us at{' '}
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
