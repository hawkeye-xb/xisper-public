import { defineComponent, ref, reactive, onMounted, watch } from 'vue'
import {
  ElCard,
  ElTable,
  ElTableColumn,
  ElInput,
  ElSelect,
  ElOption,
  ElButton,
  ElTag,
  ElPagination,
  ElMessage,
  ElMessageBox,
  ElSpace,
  ElRow,
  ElCol,
} from 'element-plus'
import { Search, Refresh } from '@element-plus/icons-vue'
import { useRouter } from 'vue-router'
import { adminApi, type UserRecord } from '../api'

export default defineComponent({
  name: 'Users',
  setup() {
    const router = useRouter()
    const loading = ref(false)
    const users = ref<UserRecord[]>([])
    const pagination = reactive({
      page: 1,
      pageSize: 20,
      total: 0,
    })
    const filters = reactive({
      search: '',
      tier: '',
      role: '',
      activeToday: '' as '' | 'yes' | 'no',
    })

    const fetchUsers = async () => {
      loading.value = true
      try {
        const res = await adminApi.listUsers({
          page: pagination.page,
          pageSize: pagination.pageSize,
          search: filters.search || undefined,
          tier: filters.tier || undefined,
          role: filters.role || undefined,
          activeToday: filters.activeToday === 'yes' ? true : filters.activeToday === 'no' ? false : undefined,
        })
        users.value = res.data
        pagination.total = res.pagination.total
      } catch (e: any) {
        ElMessage.error(e.message || 'Failed to load users')
      } finally {
        loading.value = false
      }
    }

    onMounted(fetchUsers)

    const handleSearch = () => {
      pagination.page = 1
      fetchUsers()
    }

    const handlePageChange = (page: number) => {
      pagination.page = page
      fetchUsers()
    }

    const handleSizeChange = (size: number) => {
      pagination.pageSize = size
      pagination.page = 1
      fetchUsers()
    }

    const handleViewDetail = (row: UserRecord) => {
      router.push(`/users/${row.id}`)
    }

    const handleChangeTier = async (row: UserRecord) => {
      try {
        const { value } = await ElMessageBox.prompt(
          `Current tier: ${row.tier}`,
          'Change Tier',
          {
            inputValue: row.tier,
            inputPattern: /^(free|pro|enterprise)$/,
            inputErrorMessage: 'Must be free, pro, or enterprise',
            confirmButtonText: 'Update',
          }
        )
        await adminApi.updateTier(row.id, value)
        ElMessage.success(`Tier updated to ${value}`)
        fetchUsers()
      } catch {
        // cancelled
      }
    }

    const handleChangeRole = async (row: UserRecord) => {
      const newRole = row.role === 'admin' ? 'user' : 'admin'
      try {
        await ElMessageBox.confirm(
          `Change role from "${row.role}" to "${newRole}" for ${row.email || row.id}?`,
          'Change Role',
          { confirmButtonText: 'Confirm', type: 'warning' }
        )
        await adminApi.updateRole(row.id, newRole)
        ElMessage.success(`Role updated to ${newRole}`)
        fetchUsers()
      } catch {
        // cancelled
      }
    }

    const tierTagType = (tier: string) => {
      switch (tier) {
        case 'pro': return 'success'
        case 'enterprise': return 'warning'
        case 'unlimited': return 'danger'
        default: return 'info'
      }
    }

    const formatTime = (ts: number) => {
      if (!ts) return '-'
      return new Date(ts).toLocaleString()
    }

    return () => (
      <div>
        <h2 style="margin: 0 0 24px; font-size: 20px; font-weight: 600; color: #1f2937;">
          User Management
        </h2>

        <ElCard shadow="never" style="margin-bottom: 16px;">
          <ElRow gutter={12} align="middle">
            <ElCol span={8}>
              <ElInput
                v-model={filters.search}
                placeholder="Search by email or user ID"
                prefixIcon={Search}
                clearable
                onClear={handleSearch}
                onKeyup={(e: KeyboardEvent) => e.key === 'Enter' && handleSearch()}
              />
            </ElCol>
            <ElCol span={4}>
              <ElSelect
                v-model={filters.tier}
                placeholder="Tier"
                clearable
                onChange={handleSearch}
                style="width: 100%;"
              >
                <ElOption label="Free" value="free" />
                <ElOption label="Pro" value="pro" />
                <ElOption label="Enterprise" value="enterprise" />
              </ElSelect>
            </ElCol>
            <ElCol span={4}>
              <ElSelect
                v-model={filters.role}
                placeholder="Role"
                clearable
                onChange={handleSearch}
                style="width: 100%;"
              >
                <ElOption label="User" value="user" />
                <ElOption label="Admin" value="admin" />
              </ElSelect>
            </ElCol>
            <ElCol span={4}>
              <ElSelect
                v-model={filters.activeToday}
                placeholder="Today active"
                clearable
                onChange={handleSearch}
                style="width: 100%;"
              >
                <ElOption label="All" value="" />
                <ElOption label="Yes" value="yes" />
                <ElOption label="No" value="no" />
              </ElSelect>
            </ElCol>
            <ElCol span={4}>
              <ElSpace>
                <ElButton type="primary" onClick={handleSearch} icon={Search}>
                  Search
                </ElButton>
                <ElButton onClick={fetchUsers} icon={Refresh}>
                  Refresh
                </ElButton>
              </ElSpace>
            </ElCol>
          </ElRow>
        </ElCard>

        <ElCard shadow="never">
          <ElTable data={users.value} v-loading={loading.value} stripe style="width: 100%;">
            <ElTableColumn label="Email" minWidth={200} showOverflowTooltip>
              {{
                default: ({ row }: { row: UserRecord }) => (
                  <span>{row.email || '—'}</span>
                ),
              }}
            </ElTableColumn>
            <ElTableColumn prop="id" label="User ID" width={220} showOverflowTooltip />
            <ElTableColumn label="Tier" width={120}>
              {{
                default: ({ row }: { row: UserRecord }) => (
                  <ElTag type={tierTagType(row.tier)} size="small">
                    {row.tier}
                  </ElTag>
                ),
              }}
            </ElTableColumn>
            <ElTableColumn label="Role" width={100}>
              {{
                default: ({ row }: { row: UserRecord }) => (
                  <ElTag type={row.role === 'admin' ? 'danger' : 'info'} size="small">
                    {row.role || 'user'}
                  </ElTag>
                ),
              }}
            </ElTableColumn>
            <ElTableColumn label="Today active" width={110} align="center">
              {{
                default: ({ row }: { row: UserRecord }) => (
                  row.active_today ? (
                    <ElTag type="success" size="small">Yes</ElTag>
                  ) : (
                    <span style="color: #909399;">No</span>
                  )
                ),
              }}
            </ElTableColumn>
            <ElTableColumn label="Created" width={180}>
              {{
                default: ({ row }: { row: UserRecord }) => (
                  <span style="font-size: 13px; color: #6b7280;">
                    {formatTime(row.created_at)}
                  </span>
                ),
              }}
            </ElTableColumn>
            <ElTableColumn label="Actions" width={280} fixed="right">
              {{
                default: ({ row }: { row: UserRecord }) => (
                  <ElSpace>
                    <ElButton size="small" onClick={() => handleViewDetail(row)}>
                      Detail
                    </ElButton>
                    <ElButton size="small" type="primary" onClick={() => handleChangeTier(row)}>
                      Tier
                    </ElButton>
                    <ElButton size="small" type="warning" onClick={() => handleChangeRole(row)}>
                      Role
                    </ElButton>
                  </ElSpace>
                ),
              }}
            </ElTableColumn>
          </ElTable>

          <div style="display: flex; justify-content: flex-end; margin-top: 16px;">
            <ElPagination
              v-model:currentPage={pagination.page}
              v-model:pageSize={pagination.pageSize}
              total={pagination.total}
              pageSizes={[10, 20, 50, 100]}
              layout="total, sizes, prev, pager, next"
              onCurrentChange={handlePageChange}
              onSizeChange={handleSizeChange}
            />
          </div>
        </ElCard>
      </div>
    )
  },
})
