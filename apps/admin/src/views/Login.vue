<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElCard, ElForm, ElFormItem, ElInput, ElButton, ElMessage } from 'element-plus'
import { login } from '../auth'

const router = useRouter()
const username = ref('')
const password = ref('')
const loading = ref(false)

async function handleLogin() {
  if (!username.value || !password.value) {
    ElMessage.warning('Please enter username and password')
    return
  }
  loading.value = true
  try {
    await login(username.value, password.value)
    router.push('/')
  } catch (e: any) {
    ElMessage.error(e.message || 'Login failed')
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="login-container">
    <ElCard class="login-card" shadow="always">
      <template #header>
        <div class="login-header">
          <h2>Xisper Admin</h2>
        </div>
      </template>
      <ElForm @submit.prevent="handleLogin">
        <ElFormItem>
          <ElInput
            v-model="username"
            placeholder="Username"
            size="large"
            :prefix-icon="'User'"
            autofocus
          />
        </ElFormItem>
        <ElFormItem>
          <ElInput
            v-model="password"
            type="password"
            placeholder="Password"
            size="large"
            show-password
            @keyup.enter="handleLogin"
          />
        </ElFormItem>
        <ElFormItem>
          <ElButton
            type="primary"
            size="large"
            :loading="loading"
            style="width: 100%"
            @click="handleLogin"
          >
            Sign In
          </ElButton>
        </ElFormItem>
      </ElForm>
    </ElCard>
  </div>
</template>

<style scoped>
.login-container {
  display: flex;
  justify-content: center;
  align-items: center;
  height: 100vh;
  background: #f0f2f5;
}
.login-card {
  width: 400px;
}
.login-header {
  text-align: center;
}
.login-header h2 {
  margin: 0;
  color: #001529;
  font-size: 24px;
}
</style>
