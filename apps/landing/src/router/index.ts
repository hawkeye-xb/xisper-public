import type { RouteRecordRaw } from 'vue-router'

export const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'home',
    component: () => import('../pages/LandingPage'),
  },
  {
    path: '/pricing',
    name: 'pricing',
    component: () => import('../pages/PricingPage'),
  },
  {
    path: '/privacy',
    name: 'privacy',
    component: () => import('../pages/PrivacyPolicy'),
  },
  {
    path: '/terms',
    name: 'terms',
    component: () => import('../pages/TermsOfService'),
  },
  {
    path: '/refund',
    name: 'refund',
    component: () => import('../pages/RefundPolicy'),
  },
]
