import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import { isAuthenticated } from './auth'

const routes: RouteRecordRaw[] = [
  {
    path: '/login',
    name: 'login',
    component: () => import('./views/Login.vue'),
  },
  {
    path: '/',
    component: () => import('./layouts/AdminLayout'),
    meta: { requiresAuth: true },
    children: [
      {
        path: '',
        name: 'dashboard',
        component: () => import('./views/Dashboard'),
      },
      {
        path: 'users',
        name: 'users',
        component: () => import('./views/Users'),
      },
      {
        path: 'users/:id',
        name: 'user-detail',
        component: () => import('./views/UserDetail'),
        props: true,
      },
      {
        path: 'prompts',
        name: 'prompts',
        component: () => import('./views/Prompts'),
      },
      {
        path: 'identities',
        name: 'identities',
        component: () => import('./views/Identities'),
      },
      {
        path: 'identities/:id',
        name: 'identity-detail',
        component: () => import('./views/IdentityDetail'),
        props: true,
      },
      {
        path: 'releases',
        name: 'releases',
        component: () => import('./views/AppPublish'),
      },
    ],
  },
]

export const router = createRouter({
  history: createWebHistory(),
  routes,
})

// Navigation guard
router.beforeEach((to) => {
  if (to.meta.requiresAuth && !isAuthenticated.value) {
    return { name: 'login' }
  }
  if (to.name === 'login' && isAuthenticated.value) {
    return { path: '/' }
  }
})
