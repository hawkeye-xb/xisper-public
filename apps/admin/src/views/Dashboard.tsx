import { defineComponent, ref, onMounted } from 'vue'
import {
  ElCard,
  ElRow,
  ElCol,
  ElStatistic,
  ElSkeleton,
  ElMessage,
} from 'element-plus'
import { adminApi, type SystemStats } from '../api'

export default defineComponent({
  name: 'Dashboard',
  setup() {
    const stats = ref<SystemStats | null>(null)
    const loading = ref(true)

    const fetchStats = async () => {
      loading.value = true
      try {
        const res = await adminApi.getStats()
        stats.value = res.data
      } catch (e: any) {
        ElMessage.error(e.message || 'Failed to load stats')
      } finally {
        loading.value = false
      }
    }

    onMounted(fetchStats)

    const getTierCount = (tier: string) => {
      if (!stats.value) return 0
      const item = stats.value.tierDistribution.find((t) => t.tier === tier)
      return item?.count || 0
    }

    return () => (
      <div>
        <h2 style="margin: 0 0 24px; font-size: 20px; font-weight: 600; color: #1f2937;">
          Dashboard
        </h2>

        {loading.value ? (
          <ElSkeleton rows={4} animated />
        ) : stats.value ? (
          <>
            <ElRow gutter={16} style="margin-bottom: 24px;">
              <ElCol span={6}>
                <ElCard shadow="hover" bodyStyle={{ padding: '20px' }}>
                  <ElStatistic title="Total Users" value={stats.value.totalUsers} />
                </ElCard>
              </ElCol>
              <ElCol span={6}>
                <ElCard shadow="hover" bodyStyle={{ padding: '20px' }}>
                  <ElStatistic title="Recent Signups (7d)" value={stats.value.recentSignups} />
                </ElCard>
              </ElCol>
              <ElCol span={6}>
                <ElCard shadow="hover" bodyStyle={{ padding: '20px' }}>
                  <ElStatistic title="Today Active" value={stats.value.todayActive} />
                </ElCard>
              </ElCol>
              <ElCol span={6}>
                <ElCard shadow="hover" bodyStyle={{ padding: '20px' }}>
                  <ElStatistic
                    title="Admin Users"
                    value={
                      stats.value.roleDistribution.find((r) => r.role === 'admin')?.count || 0
                    }
                  />
                </ElCard>
              </ElCol>
            </ElRow>

            <h3 style="margin: 0 0 16px; font-size: 16px; font-weight: 600; color: #374151;">
              Tier Distribution
            </h3>
            <ElRow gutter={16}>
              <ElCol span={8}>
                <ElCard shadow="hover" bodyStyle={{ padding: '20px' }}>
                  <ElStatistic title="Free" value={getTierCount('free')} />
                </ElCard>
              </ElCol>
              <ElCol span={8}>
                <ElCard shadow="hover" bodyStyle={{ padding: '20px' }}>
                  <ElStatistic title="Pro" value={getTierCount('pro')} />
                </ElCard>
              </ElCol>
              <ElCol span={8}>
                <ElCard shadow="hover" bodyStyle={{ padding: '20px' }}>
                  <ElStatistic title="Enterprise" value={getTierCount('enterprise')} />
                </ElCard>
              </ElCol>
            </ElRow>
          </>
        ) : (
          <ElCard>
            <p style="text-align: center; color: #909399;">No data available</p>
          </ElCard>
        )}
      </div>
    )
  },
})
