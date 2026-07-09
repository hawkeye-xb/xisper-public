import { defineComponent, ref } from 'vue'
import {
  ElCard,
  ElButton,
  ElMessage,
  ElMessageBox,
  ElRow,
  ElCol,
  ElTag,
  ElAlert,
  ElCheckbox,
} from 'element-plus'
import { adminApi } from '../api'

export default defineComponent({
  name: 'AppPublish',
  setup() {
    const macBetaLoading = ref(false)
    const macProdLoading = ref(false)
    const macBetaCritical = ref(false)
    const macProdCritical = ref(false)

    const handleMacNativePublish = async (channel: 'beta' | 'production') => {
      const label = channel === 'beta' ? 'Beta' : 'Production'
      const isCritical = channel === 'beta' ? macBetaCritical.value : macProdCritical.value

      const warningText = isCritical
        ? `⚠️ CRITICAL UPDATE\n\nThis will force ALL users to update. Users cannot skip or delay this update.\n\nAre you sure?`
        : `This will promote the Mac native appcast-pre.xml to live appcast.xml for the ${label} channel. Sparkle will notify users of the new version.`

      const boxType = isCritical ? 'error' : 'warning'

      try {
        await ElMessageBox.confirm(
          warningText,
          `Publish Mac Native to ${label}?`,
          { confirmButtonText: 'Publish', cancelButtonText: 'Cancel', type: boxType },
        )
      } catch {
        return
      }

      const loading = channel === 'beta' ? macBetaLoading : macProdLoading
      loading.value = true
      try {
        const res = await adminApi.publishMacNativeRelease(channel, { criticalUpdate: isCritical })
        ElMessage.success(res.data?.message || `Mac native published to ${label} successfully`)
      } catch (e: any) {
        ElMessage.error(e.message || `Failed to publish Mac native to ${label}`)
      } finally {
        loading.value = false
      }
    }

    return () => (
      <div>
        <h2 style="margin: 0 0 24px; font-size: 20px; font-weight: 600; color: #1f2937;">
          App Releases
        </h2>

        {/* ── Mac Native (Sparkle) ── */}

        <ElAlert
          title="Mac Native (Sparkle) — Publish promotes appcast-pre.xml to appcast.xml in R2. Sparkle will notify native macOS app users of the new version."
          type="info"
          showIcon
          closable={false}
          style="margin-bottom: 24px;"
        />

        <ElRow gutter={24}>
          <ElCol span={12}>
            <ElCard shadow="hover">
              <div style="display: flex; flex-direction: column; gap: 16px;">
                <div style="display: flex; align-items: center; gap: 8px;">
                  <h3 style="margin: 0; font-size: 18px; font-weight: 600;">Beta Channel</h3>
                  <ElTag type="warning" size="small">beta</ElTag>
                  <ElTag type="success" size="small">Mac Native</ElTag>
                </div>
                <p style="margin: 0; color: #6b7280; font-size: 14px; line-height: 1.6;">
                  Publish the latest native macOS build to beta testers via Sparkle.
                  <code style="background: #f3f4f6; padding: 2px 6px; border-radius: 4px; font-size: 12px;">
                    mac-beta/appcast-pre.xml → appcast.xml
                  </code>
                </p>
                <div style="display: flex; align-items: center; gap: 12px;">
                  <ElCheckbox
                    v-model={macBetaCritical.value}
                    label="Force critical update"
                  />
                  <span style="color: #ef4444; font-size: 12px; font-weight: 500;">
                    {macBetaCritical.value && '⚠️ Users cannot skip this update'}
                  </span>
                </div>
                <ElButton
                  type="warning"
                  loading={macBetaLoading.value}
                  onClick={() => handleMacNativePublish('beta')}
                  style="align-self: flex-start;"
                >
                  Publish Mac Native to Beta
                </ElButton>
              </div>
            </ElCard>
          </ElCol>

          <ElCol span={12}>
            <ElCard shadow="hover">
              <div style="display: flex; flex-direction: column; gap: 16px;">
                <div style="display: flex; align-items: center; gap: 8px;">
                  <h3 style="margin: 0; font-size: 18px; font-weight: 600;">Production Channel</h3>
                  <ElTag type="danger" size="small">production</ElTag>
                  <ElTag type="success" size="small">Mac Native</ElTag>
                </div>
                <p style="margin: 0; color: #6b7280; font-size: 14px; line-height: 1.6;">
                  Publish the latest native macOS build to all users via Sparkle.
                  <code style="background: #f3f4f6; padding: 2px 6px; border-radius: 4px; font-size: 12px;">
                    mac-production/appcast-pre.xml → appcast.xml
                  </code>
                </p>
                <div style="display: flex; align-items: center; gap: 12px;">
                  <ElCheckbox
                    v-model={macProdCritical.value}
                    label="Force critical update"
                  />
                  <span style="color: #ef4444; font-size: 12px; font-weight: 500;">
                    {macProdCritical.value && '⚠️ Users cannot skip this update'}
                  </span>
                </div>
                <ElButton
                  type="danger"
                  loading={macProdLoading.value}
                  onClick={() => handleMacNativePublish('production')}
                  style="align-self: flex-start;"
                >
                  Publish Mac Native to Production
                </ElButton>
              </div>
            </ElCard>
          </ElCol>
        </ElRow>
      </div>
    )
  },
})
