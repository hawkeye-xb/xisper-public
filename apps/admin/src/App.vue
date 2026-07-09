<script setup lang="ts">
import { setTokenGetter } from './api'
import { getToken } from './auth'

// Wire up the API client token getter
setTokenGetter(async () => getToken() ?? undefined)
</script>

<template>
  <router-view />
</template>

<style>
body {
  margin: 0;
  padding: 0;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
  background: #f5f7fa;
}
</style>
