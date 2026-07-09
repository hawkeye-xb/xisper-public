import { defineComponent } from 'vue'

const LAST_UPDATED = 'April 6, 2026'
const CONTACT_EMAIL = 'support@hawkeye-xb.com'

export default defineComponent({
  name: 'RefundPolicy',
  setup() {
    return () => (
      <article class="max-w-[720px] mx-auto px-6 py-20">
        <h1 class="text-4xl font-bold text-text-primary mb-2">Refund Policy</h1>
        <p class="text-sm text-text-muted mb-12">Last Updated: {LAST_UPDATED}</p>

        <div class="flex flex-col gap-8 text-[15px] leading-relaxed text-text-secondary">
          <p>
            We want you to be completely satisfied with Xisper. If you are not
            satisfied with the Service, we offer a full refund within 14 days of
            purchase.
          </p>

          <section>
            <h2 class="text-xl font-semibold text-text-primary mb-3">
              Eligibility for Refund
            </h2>
            <p>
              To be eligible for a full refund, you must request it within 14 days from
              the date of purchase. Refund requests made after this period will not
              be accepted.
            </p>
          </section>

          <section>
            <h2 class="text-xl font-semibold text-text-primary mb-3">
              How to Request a Refund
            </h2>
            <p>
              To request a refund, please contact us at{' '}
              <a
                href={`mailto:${CONTACT_EMAIL}`}
                class="text-accent hover:text-accent-light transition-colors"
              >
                {CONTACT_EMAIL}
              </a>{' '}
              with your order details, including:
            </p>
            <ul class="list-disc pl-5 mt-2 flex flex-col gap-1.5">
              <li>The email address used for the purchase</li>
              <li>The date of purchase</li>
              <li>Your order number (if available)</li>
            </ul>
          </section>

          <section>
            <h2 class="text-xl font-semibold text-text-primary mb-3">
              Refund Process
            </h2>
            <p>
              Once we receive your refund request, we will review it and notify
              you of the decision within 3-5 business days. If your request
              is approved, the refund will be issued to your original payment
              method. Please note that processing time may vary depending on
              your payment provider.
            </p>
          </section>

          <section>
            <h2 class="text-xl font-semibold text-text-primary mb-3">
              Changes to This Policy
            </h2>
            <p>
              We reserve the right to modify this Refund Policy at any time.
              Any changes will be posted on this page with an updated "Last
              Updated" date.
            </p>
          </section>

          <section>
            <h2 class="text-xl font-semibold text-text-primary mb-3">
              Contact Us
            </h2>
            <p>
              If you have questions about this Refund Policy, please contact us
              at{' '}
              <a
                href={`mailto:${CONTACT_EMAIL}`}
                class="text-accent hover:text-accent-light transition-colors"
              >
                {CONTACT_EMAIL}
              </a>.
            </p>
          </section>
        </div>
      </article>
    )
  },
})