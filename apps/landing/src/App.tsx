import { defineComponent } from 'vue'
import { RouterView } from 'vue-router'
import Header from './sections/Header'
import Footer from './sections/Footer'

export default defineComponent({
  name: 'App',
  setup() {
    return () => (
      <div class="min-h-screen bg-bg-primary flex flex-col">
        <Header />
        <main class="flex-1">
          <RouterView />
        </main>
        <Footer />
      </div>
    )
  },
})
