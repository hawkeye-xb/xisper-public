import { defineComponent, ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import {
  ElTable,
  ElTableColumn,
  ElButton,
  ElTag,
  ElMessage,
  ElMessageBox,
  ElCard,
} from 'element-plus'
import { Plus } from '@element-plus/icons-vue'
import { adminApi, type IdentityIndex } from '../api'

export default defineComponent({
  name: 'Identities',
  setup() {
    const router = useRouter()
    const loading = ref(false)
    const identities = ref<IdentityIndex[]>([])

    const fetchIdentities = async () => {
      loading.value = true
      try {
        const res = await adminApi.listIdentities()
        identities.value = res.data
      } catch (e: any) {
        ElMessage.error(e.message || 'Failed to load identities')
      } finally {
        loading.value = false
      }
    }

    const handleCreate = async () => {
      try {
        const { value: id } = await ElMessageBox.prompt('Enter identity ID (slug, e.g. "developer")', 'Create Identity', {
          confirmButtonText: 'Create',
          cancelButtonText: 'Cancel',
          inputPattern: /^[a-z0-9_-]+$/,
          inputErrorMessage: 'ID must be lowercase alphanumeric with hyphens/underscores',
        })
        if (id) {
          await adminApi.createIdentity({
            id: id.trim(),
            label: id.trim(),
            corrections: [],
            enabled: true,
          })
          ElMessage.success('Created')
          router.push(`/identities/${id.trim()}`)
        }
      } catch {
        // cancelled
      }
    }

    const handleToggle = async (identity: IdentityIndex) => {
      try {
        await adminApi.updateIdentity(identity.id, { enabled: !identity.enabled })
        identity.enabled = !identity.enabled
        ElMessage.success(identity.enabled ? 'Enabled' : 'Disabled')
      } catch (e: any) {
        ElMessage.error(e.message)
      }
    }

    const handleDelete = async (identity: IdentityIndex) => {
      try {
        await ElMessageBox.confirm(
          `Delete identity "${identity.label}"? This cannot be undone.`,
          'Delete',
          { confirmButtonText: 'Delete', cancelButtonText: 'Cancel', type: 'warning' },
        )
        await adminApi.deleteIdentity(identity.id)
        ElMessage.success('Deleted')
        fetchIdentities()
      } catch {
        // cancelled
      }
    }

    const formatDate = (ts: number) => {
      return new Date(ts).toLocaleString()
    }

    onMounted(fetchIdentities)

    return () => (
      <div style="padding: 24px;">
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
          <h2 style="margin: 0;">Identities</h2>
          <ElButton type="primary" icon={Plus} onClick={handleCreate}>
            Create Identity
          </ElButton>
        </div>

        <ElCard shadow="never">
          <ElTable data={identities.value} loading={loading.value} style="width: 100%;">
            <ElTableColumn prop="id" label="ID" width={160} />
            <ElTableColumn prop="label" label="Label" width={200} />
            <ElTableColumn prop="description" label="Description" show-overflow-tooltip />
            <ElTableColumn prop="correctionCount" label="Corrections" width={110} align="center" />
            <ElTableColumn label="Vocabulary" width={140} v-slots={{
              default: ({ row }: { row: IdentityIndex }) => (
                row.vocabularyId
                  ? <ElTag size="small" type="info">{row.vocabularyId}</ElTag>
                  : <span style="color: var(--el-text-color-placeholder);">—</span>
              ),
            }} />
            <ElTableColumn label="Status" width={100} align="center" v-slots={{
              default: ({ row }: { row: IdentityIndex }) => (
                <ElTag type={row.enabled ? 'success' : 'info'} size="small">
                  {row.enabled ? 'Enabled' : 'Disabled'}
                </ElTag>
              ),
            }} />
            <ElTableColumn label="Updated" width={180} v-slots={{
              default: ({ row }: { row: IdentityIndex }) => (
                <span>{formatDate(row.updatedAt)}</span>
              ),
            }} />
            <ElTableColumn label="Actions" width={240} fixed="right" v-slots={{
              default: ({ row }: { row: IdentityIndex }) => (
                <div style="display: flex; gap: 8px;">
                  <ElButton size="small" type="primary" link onClick={() => router.push(`/identities/${row.id}`)}>
                    Edit
                  </ElButton>
                  <ElButton size="small" type="primary" link onClick={() => handleToggle(row)}>
                    {row.enabled ? 'Disable' : 'Enable'}
                  </ElButton>
                  <ElButton size="small" type="danger" link onClick={() => handleDelete(row)}>
                    Delete
                  </ElButton>
                </div>
              ),
            }} />
          </ElTable>
        </ElCard>
      </div>
    )
  },
})
