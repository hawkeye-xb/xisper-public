import { defineComponent } from 'vue'
import Hero from '../sections/Hero'
import Highlights from '../sections/Highlights'
import RoleShowcase from '../sections/RoleShowcase'
import CoreFeatures from '../sections/CoreFeatures'
import HowItWorks from '../sections/HowItWorks'
import FeatureGrid from '../sections/FeatureGrid'
import FinalCTA from '../sections/FinalCTA'

export default defineComponent({
  name: 'LandingPage',
  setup() {
    return () => (
      <>
        <Hero />
        <Highlights />
        <RoleShowcase />
        <CoreFeatures />
        <HowItWorks />
        <FeatureGrid />
        <FinalCTA />
      </>
    )
  },
})
