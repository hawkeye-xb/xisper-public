import { defineComponent, computed } from 'vue'
import { useRouter, useRoute, RouterView } from 'vue-router'
import { logout, getUsername } from '../auth'
import {
  ElContainer,
  ElAside,
  ElMain,
  ElMenu,
  ElMenuItem,
  ElHeader,
  ElDropdown,
  ElDropdownMenu,
  ElDropdownItem,
  ElIcon,
} from 'element-plus'
import { DataBoard, User, ArrowDown, EditPen, Upload, Collection } from '@element-plus/icons-vue'

export default defineComponent({
  name: 'AdminLayout',
  setup() {
    const router = useRouter()
    const route = useRoute()

    const activeMenu = computed(() => {
      if (route.path.startsWith('/users')) return '/users'
      if (route.path.startsWith('/prompts')) return '/prompts'
      if (route.path.startsWith('/identities')) return '/identities'
      if (route.path.startsWith('/releases')) return '/releases'
      return route.path
    })

    const handleMenuSelect = (path: string) => {
      router.push(path)
    }

    const handleSignOut = () => {
      logout()
      router.push('/login')
    }

    return () => (
      <ElContainer style="height: 100vh;">
        <ElAside width="220px" style="background: #001529;">
          <div style="padding: 20px; text-align: center; color: #fff; font-size: 18px; font-weight: 600; border-bottom: 1px solid rgba(255,255,255,0.1);">
            Xisper Admin
          </div>
          <ElMenu
            defaultActive={activeMenu.value}
            backgroundColor="#001529"
            textColor="#ffffffa6"
            activeTextColor="#fff"
            onSelect={handleMenuSelect}
            style="border-right: none;"
          >
            <ElMenuItem index="/">
              <ElIcon><DataBoard /></ElIcon>
              <span>Dashboard</span>
            </ElMenuItem>
            <ElMenuItem index="/users">
              <ElIcon><User /></ElIcon>
              <span>Users</span>
            </ElMenuItem>
            <ElMenuItem index="/prompts">
              <ElIcon><EditPen /></ElIcon>
              <span>Prompts</span>
            </ElMenuItem>
            <ElMenuItem index="/identities">
              <ElIcon><Collection /></ElIcon>
              <span>Identities</span>
            </ElMenuItem>
            <ElMenuItem index="/releases">
              <ElIcon><Upload /></ElIcon>
              <span>App Releases</span>
            </ElMenuItem>
          </ElMenu>
        </ElAside>
        <ElContainer>
          <ElHeader style="background: #fff; display: flex; align-items: center; justify-content: flex-end; box-shadow: 0 1px 4px rgba(0,0,0,0.08); z-index: 1; padding: 0 24px;">
            <ElDropdown>
              {{
                default: () => (
                  <span style="cursor: pointer; display: flex; align-items: center; gap: 6px; color: #333; font-size: 14px;">
                    {getUsername() || 'Admin'}
                    <ElIcon><ArrowDown /></ElIcon>
                  </span>
                ),
                dropdown: () => (
                  <ElDropdownMenu>
                    <ElDropdownItem onClick={handleSignOut}>Sign Out</ElDropdownItem>
                  </ElDropdownMenu>
                ),
              }}
            </ElDropdown>
          </ElHeader>
          <ElMain style="background: #f0f2f5; overflow-y: auto;">
            <RouterView />
          </ElMain>
        </ElContainer>
      </ElContainer>
    )
  },
})
