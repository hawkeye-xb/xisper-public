import { defineComponent } from 'vue'
import { RouterLink } from 'vue-router'

export default defineComponent({
  name: 'SiteFooter',
  setup() {
    return () => (
      <footer class="flex flex-col px-6 md:px-[120px] pt-10 md:pt-12 pb-8 gap-8 bg-bg-footer">
        {/* Top */}
        <div class="flex flex-col md:flex-row justify-between items-start gap-8 md:gap-0">
          <div class="flex flex-col gap-3">
            <RouterLink to="/" class="text-xl font-bold text-text-primary no-underline">Xisper</RouterLink>
            <span class="text-sm text-text-muted">Your voice, your words.</span>
          </div>
          <div class="grid grid-cols-3 gap-8 md:gap-12">
            {/* Product */}
            <div class="flex flex-col gap-3">
              <span class="text-[13px] font-semibold text-text-secondary">Product</span>
              <a href="/#features" class="text-sm text-text-muted hover:text-text-secondary transition-colors">Features</a>
              <a href="/#how-it-works" class="text-sm text-text-muted hover:text-text-secondary transition-colors">How it Works</a>
              <RouterLink to="/pricing" class="text-sm text-text-muted hover:text-text-secondary transition-colors no-underline">Pricing</RouterLink>
              <a href="#download" class="text-sm text-text-muted hover:text-text-secondary transition-colors">Download</a>
            </div>
            {/* Legal */}
            <div class="flex flex-col gap-3">
              <span class="text-[13px] font-semibold text-text-secondary">Legal</span>
              <RouterLink to="/privacy" class="text-sm text-text-muted hover:text-text-secondary transition-colors no-underline">Privacy Policy</RouterLink>
              <RouterLink to="/terms" class="text-sm text-text-muted hover:text-text-secondary transition-colors no-underline">Terms of Service</RouterLink>
              <RouterLink to="/refund" class="text-sm text-text-muted hover:text-text-secondary transition-colors no-underline">Refund Policy</RouterLink>
            </div>
            {/* Support */}
            <div class="flex flex-col gap-3">
              <span class="text-[13px] font-semibold text-text-secondary">Support</span>
              <a href="mailto:support@hawkeye-xb.com" class="text-sm text-text-muted hover:text-text-secondary transition-colors">support@hawkeye-xb.com</a>
            </div>
          </div>
        </div>

        {/* Divider */}
        <div class="w-full h-px bg-border-subtle" />

        {/* Bottom */}
        <div class="flex justify-between items-center">
          <span class="text-[13px] text-text-muted">© {new Date().getFullYear()} hawkeye-xb. All rights reserved.</span>
        </div>
      </footer>
    )
  },
})
