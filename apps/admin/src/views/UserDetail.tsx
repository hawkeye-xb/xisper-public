import { defineComponent, ref, onMounted } from 'vue'
import {
  ElCard,
  ElDescriptions,
  ElDescriptionsItem,
  ElTag,
  ElButton,
  ElProgress,
  ElMessage,
  ElMessageBox,
  ElDivider,
  ElRow,
  ElCol,
  ElSkeleton,
  ElSpace,
  ElInputNumber,
  ElForm,
  ElFormItem,
} from 'element-plus'
import { ArrowLeft } from '@element-plus/icons-vue'
import { useRouter } from 'vue-router'
import { adminApi, type UserRecord, type QuotaStatus, type CustomQuotaLimits } from '../api'

export default defineComponent({
  name: 'UserDetail',
  props: {
    id: { type: String, required: true },
  },
  setup(props) {
    const router = useRouter()
    const loading = ref(true)
    const user = ref<(UserRecord & { quota?: QuotaStatus }) | null>(null)

    // Quota override form (set current usage)
    const quotaForm = ref({
      llm: undefined as number | undefined,
      asrDuration: undefined as number | undefined,
      asrCharacters: undefined as number | undefined,
    })

    // Custom quota limits form (per-user limit overrides)
    const limitsForm = ref({
      llmCalls: undefined as number | undefined,
      asrDuration: undefined as number | undefined,
      asrCharacters: undefined as number | undefined,
    })

    const fetchUser = async () => {
      loading.value = true
      try {
        const res = await adminApi.getUser(props.id)
        user.value = res.data
      } catch (e: any) {
        ElMessage.error(e.message || 'Failed to load user')
      } finally {
        loading.value = false
      }
    }

    onMounted(fetchUser)

    const formatTime = (ts: number) => {
      if (!ts) return '-'
      return new Date(ts).toLocaleString()
    }

    const formatDuration = (seconds: number) => {
      const h = Math.floor(seconds / 3600)
      const m = Math.floor((seconds % 3600) / 60)
      const s = seconds % 60
      if (h > 0) return `${h}h ${m}m ${s}s`
      if (m > 0) return `${m}m ${s}s`
      return `${s}s`
    }

    const quotaPercent = (used: number, limit: number) => {
      if (limit === 0) return 0
      return Math.min(100, Math.round((used / limit) * 100))
    }

    const quotaColor = (percent: number) => {
      if (percent >= 90) return '#f56c6c'
      if (percent >= 70) return '#e6a23c'
      return '#67c23a'
    }

    const handleResetQuota = async () => {
      try {
        await ElMessageBox.confirm(
          'This will reset all quota counters for this user. Continue?',
          'Reset Quota',
          { confirmButtonText: 'Reset', type: 'warning' }
        )
        await adminApi.resetQuota(props.id)
        ElMessage.success('Quota reset successfully')
        fetchUser()
      } catch {
        // cancelled
      }
    }

    const handleOverrideQuota = async () => {
      const overrides: Record<string, number> = {}
      if (quotaForm.value.llm !== undefined) overrides.llm = quotaForm.value.llm
      if (quotaForm.value.asrDuration !== undefined) overrides.asrDuration = quotaForm.value.asrDuration
      if (quotaForm.value.asrCharacters !== undefined) overrides.asrCharacters = quotaForm.value.asrCharacters

      if (Object.keys(overrides).length === 0) {
        ElMessage.warning('No quota values specified')
        return
      }

      try {
        await adminApi.overrideQuota(props.id, overrides)
        ElMessage.success('Quota overridden successfully')
        quotaForm.value = { llm: undefined, asrDuration: undefined, asrCharacters: undefined }
        fetchUser()
      } catch (e: any) {
        ElMessage.error(e.message || 'Failed to override quota')
      }
    }

    const handleChangeTier = async () => {
      if (!user.value) return
      try {
        const { value } = await ElMessageBox.prompt(
          `Current tier: ${user.value.tier}\nAvailable: free, pro, enterprise, unlimited`,
          'Change Tier',
          {
            inputValue: user.value.tier,
            inputPattern: /^(free|pro|enterprise|unlimited)$/,
            inputErrorMessage: 'Must be free, pro, enterprise, or unlimited',
            confirmButtonText: 'Update',
          }
        )
        await adminApi.updateTier(props.id, value)
        ElMessage.success(`Tier updated to ${value}`)
        fetchUser()
      } catch {
        // cancelled
      }
    }

    const handleSetCustomLimits = async () => {
      const limits: Partial<CustomQuotaLimits> = {}
      if (limitsForm.value.llmCalls !== undefined) limits.llmCalls = limitsForm.value.llmCalls
      if (limitsForm.value.asrDuration !== undefined) limits.asrDuration = limitsForm.value.asrDuration
      if (limitsForm.value.asrCharacters !== undefined) limits.asrCharacters = limitsForm.value.asrCharacters

      if (Object.keys(limits).length === 0) {
        ElMessage.warning('No limit values specified')
        return
      }

      try {
        await adminApi.setCustomLimits(props.id, limits)
        ElMessage.success('Custom quota limits updated')
        limitsForm.value = { llmCalls: undefined, asrDuration: undefined, asrCharacters: undefined }
        fetchUser()
      } catch (e: any) {
        ElMessage.error(e.message || 'Failed to set custom limits')
      }
    }

    const handleClearCustomLimits = async () => {
      try {
        await ElMessageBox.confirm(
          'This will remove all custom quota limits and revert to tier defaults. Continue?',
          'Clear Custom Limits',
          { confirmButtonText: 'Clear', type: 'warning' }
        )
        await adminApi.clearCustomLimits(props.id)
        ElMessage.success('Custom limits cleared, reverted to tier defaults')
        limitsForm.value = { llmCalls: undefined, asrDuration: undefined, asrCharacters: undefined }
        fetchUser()
      } catch {
        // cancelled
      }
    }

    return () => (
      <div>
        <ElButton
          text
          icon={ArrowLeft}
          onClick={() => router.push('/users')}
          style="margin-bottom: 16px;"
        >
          Back to Users
        </ElButton>

        {loading.value ? (
          <ElSkeleton rows={8} animated />
        ) : user.value ? (
          <>
            {/* User Info */}
            <ElCard shadow="never" style="margin-bottom: 16px;">
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
                <h3 style="margin: 0; font-size: 18px; color: #1f2937;">User Info</h3>
                <ElSpace>
                  <ElButton type="primary" size="small" onClick={handleChangeTier}>
                    Change Tier
                  </ElButton>
                </ElSpace>
              </div>
              <ElDescriptions column={2} border>
                <ElDescriptionsItem label="User ID">{user.value.id}</ElDescriptionsItem>
                <ElDescriptionsItem label="Email">{user.value.email || '-'}</ElDescriptionsItem>
                <ElDescriptionsItem label="Tier">
                  <ElTag
                    type={
                      user.value.tier === 'unlimited'
                        ? 'danger'
                        : user.value.tier === 'enterprise'
                        ? 'warning'
                        : user.value.tier === 'pro'
                        ? 'success'
                        : 'info'
                    }
                  >
                    {user.value.tier}
                  </ElTag>
                </ElDescriptionsItem>
                <ElDescriptionsItem label="Role">
                  <ElTag type={user.value.role === 'admin' ? 'danger' : 'info'}>
                    {user.value.role || 'user'}
                  </ElTag>
                </ElDescriptionsItem>
                <ElDescriptionsItem label="Created">{formatTime(user.value.created_at)}</ElDescriptionsItem>
                <ElDescriptionsItem label="Updated">{formatTime(user.value.updated_at)}</ElDescriptionsItem>
              </ElDescriptions>
            </ElCard>

            {/* Quota Status */}
            {user.value.quota && (
              <ElCard shadow="never" style="margin-bottom: 16px;">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
                  <h3 style="margin: 0; font-size: 18px; color: #1f2937;">Quota Status</h3>
                  <ElButton type="danger" size="small" onClick={handleResetQuota}>
                    Reset All Quota
                  </ElButton>
                </div>

                <ElRow gutter={24}>
                  {/* LLM Quota */}
                  <ElCol span={8}>
                    <ElCard shadow="hover" bodyStyle={{ padding: '16px' }}>
                      <h4 style="margin: 0 0 12px; color: #374151;">LLM Calls (Daily)</h4>
                      {(() => {
                        const q = user.value!.quota!.llm
                        const pct = quotaPercent(q.used, q.limit)
                        return (
                          <>
                            <ElProgress
                              percentage={pct}
                              color={quotaColor(pct)}
                              strokeWidth={12}
                            />
                            <p style="margin: 8px 0 0; font-size: 13px; color: #6b7280;">
                              {q.used} / {q.limit} used ({q.remaining} remaining)
                            </p>
                          </>
                        )
                      })()}
                    </ElCard>
                  </ElCol>

                  {/* ASR Duration */}
                  <ElCol span={8}>
                    <ElCard shadow="hover" bodyStyle={{ padding: '16px' }}>
                      <h4 style="margin: 0 0 12px; color: #374151;">ASR Duration (Weekly)</h4>
                      {(() => {
                        const q = user.value!.quota!.asr.duration
                        const pct = quotaPercent(q.used, q.limit)
                        return (
                          <>
                            <ElProgress
                              percentage={pct}
                              color={quotaColor(pct)}
                              strokeWidth={12}
                            />
                            <p style="margin: 8px 0 0; font-size: 13px; color: #6b7280;">
                              {formatDuration(q.used)} / {formatDuration(q.limit)}
                            </p>
                          </>
                        )
                      })()}
                    </ElCard>
                  </ElCol>

                  {/* ASR Characters */}
                  <ElCol span={8}>
                    <ElCard shadow="hover" bodyStyle={{ padding: '16px' }}>
                      <h4 style="margin: 0 0 12px; color: #374151;">ASR Characters (Weekly)</h4>
                      {(() => {
                        const q = user.value!.quota!.asr.characters
                        const pct = quotaPercent(q.used, q.limit)
                        return (
                          <>
                            <ElProgress
                              percentage={pct}
                              color={quotaColor(pct)}
                              strokeWidth={12}
                            />
                            <p style="margin: 8px 0 0; font-size: 13px; color: #6b7280;">
                              {q.used.toLocaleString()} / {q.limit.toLocaleString()}
                            </p>
                          </>
                        )
                      })()}
                    </ElCard>
                  </ElCol>
                </ElRow>
              </ElCard>
            )}

            {/* Custom Quota Limits */}
            <ElCard shadow="never" style="margin-bottom: 16px;">
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
                <div>
                  <h3 style="margin: 0; font-size: 18px; color: #1f2937;">Custom Quota Limits</h3>
                  <p style="margin: 4px 0 0; font-size: 13px; color: #9ca3af;">
                    Override tier defaults with per-user limits. Leave empty to keep tier default.
                  </p>
                </div>
                {user.value?.quota?.customLimits && (
                  <ElButton type="warning" size="small" onClick={handleClearCustomLimits}>
                    Clear Custom Limits
                  </ElButton>
                )}
              </div>

              {user.value?.quota?.customLimits && (
                <div style="margin-bottom: 16px; padding: 12px; background: #fef9c3; border-radius: 6px; font-size: 13px;">
                  <strong>Active custom limits: </strong>
                  {user.value.quota.customLimits.llmCalls && (
                    <ElTag size="small" type="warning" style="margin-right: 8px;">
                      LLM: {user.value.quota.customLimits.llmCalls.toLocaleString()} calls/day
                    </ElTag>
                  )}
                  {user.value.quota.customLimits.asrDuration && (
                    <ElTag size="small" type="warning" style="margin-right: 8px;">
                      ASR Duration: {formatDuration(user.value.quota.customLimits.asrDuration)}/week
                    </ElTag>
                  )}
                  {user.value.quota.customLimits.asrCharacters && (
                    <ElTag size="small" type="warning" style="margin-right: 8px;">
                      ASR Chars: {user.value.quota.customLimits.asrCharacters.toLocaleString()}/week
                    </ElTag>
                  )}
                </div>
              )}

              <ElForm inline labelPosition="top">
                <ElFormItem label="LLM Calls Limit (daily)">
                  <ElInputNumber
                    v-model={limitsForm.value.llmCalls}
                    min={0}
                    placeholder="Tier default"
                    controlsPosition="right"
                    style="width: 180px;"
                  />
                </ElFormItem>
                <ElFormItem label="ASR Duration Limit (s, weekly)">
                  <ElInputNumber
                    v-model={limitsForm.value.asrDuration}
                    min={0}
                    placeholder="Tier default"
                    controlsPosition="right"
                    style="width: 180px;"
                  />
                </ElFormItem>
                <ElFormItem label="ASR Chars Limit (weekly)">
                  <ElInputNumber
                    v-model={limitsForm.value.asrCharacters}
                    min={0}
                    placeholder="Tier default"
                    controlsPosition="right"
                    style="width: 180px;"
                  />
                </ElFormItem>
                <ElFormItem label=" ">
                  <ElButton type="primary" onClick={handleSetCustomLimits}>
                    Set Custom Limits
                  </ElButton>
                </ElFormItem>
              </ElForm>
            </ElCard>

            {/* Quota Override (Set Usage) */}
            <ElCard shadow="never">
              <h3 style="margin: 0 0 16px; font-size: 18px; color: #1f2937;">
                Override Quota (Set Usage)
              </h3>
              <p style="margin: 0 0 16px; font-size: 13px; color: #9ca3af;">
                Set the current usage counters to specific values. Leave empty to skip.
              </p>
              <ElForm inline labelPosition="top">
                <ElFormItem label="LLM Calls Used">
                  <ElInputNumber
                    v-model={quotaForm.value.llm}
                    min={0}
                    placeholder="Leave empty"
                    controlsPosition="right"
                    style="width: 180px;"
                  />
                </ElFormItem>
                <ElFormItem label="ASR Duration Used (s)">
                  <ElInputNumber
                    v-model={quotaForm.value.asrDuration}
                    min={0}
                    placeholder="Leave empty"
                    controlsPosition="right"
                    style="width: 180px;"
                  />
                </ElFormItem>
                <ElFormItem label="ASR Chars Used">
                  <ElInputNumber
                    v-model={quotaForm.value.asrCharacters}
                    min={0}
                    placeholder="Leave empty"
                    controlsPosition="right"
                    style="width: 180px;"
                  />
                </ElFormItem>
                <ElFormItem label=" ">
                  <ElButton type="primary" onClick={handleOverrideQuota}>
                    Apply Override
                  </ElButton>
                </ElFormItem>
              </ElForm>
            </ElCard>
          </>
        ) : (
          <ElCard>
            <p style="text-align: center; color: #909399;">User not found</p>
          </ElCard>
        )}
      </div>
    )
  },
})
