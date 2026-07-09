import { defineComponent, ref, computed, onMounted } from 'vue'
import {
  ElCard,
  ElTabs,
  ElTabPane,
  ElInput,
  ElButton,
  ElMessage,
  ElMessageBox,
  ElDescriptions,
  ElDescriptionsItem,
  ElTag,
  ElAlert,
  ElSpace,
  ElCollapse,
  ElCollapseItem,
} from 'element-plus'
import { adminApi, type PromptTemplate } from '../api'

const VOICE_MODES = [
  { key: 'dictation', label: 'Dictation' },
  { key: 'command', label: 'Command' },
  { key: 'conversation', label: 'Conversation' },
] as const

const PLACEHOLDERS = [
  { name: '{{MODE}}', desc: 'Processing mode directive (clean / rewrite)' },
  { name: '{{ALLOWED_OPERATIONS}}', desc: 'Enabled operations list' },
  { name: '{{HOTWORDS}}', desc: 'Hotword constraints' },
  { name: '{{CONTEXT}}', desc: 'Runtime application context' },
]

export default defineComponent({
  name: 'Prompts',
  setup() {
    const activeTab = ref('dictation')
    const templates = ref<Record<string, PromptTemplate | null>>({
      dictation: null,
      command: null,
      conversation: null,
    })
    const editBuffers = ref<Record<string, string>>({
      dictation: '',
      command: '',
      conversation: '',
    })
    const saving = ref(false)
    const loading = ref(true)

    const loadAll = async () => {
      loading.value = true
      try {
        const res = await adminApi.listPrompts()
        for (const item of res.data) {
          templates.value[item.voiceMode] = item
          editBuffers.value[item.voiceMode] = item.template ?? item.defaultTemplate
        }
      } catch (e: any) {
        ElMessage.error(`Failed to load templates: ${e.message}`)
      } finally {
        loading.value = false
      }
    }

    onMounted(loadAll)

    const isModified = (voiceMode: string) => {
      const tpl = templates.value[voiceMode]
      if (!tpl) return false
      const original = tpl.template ?? tpl.defaultTemplate
      return editBuffers.value[voiceMode] !== original
    }

    const handleSave = async (voiceMode: string) => {
      const content = editBuffers.value[voiceMode]
      if (!content?.trim()) {
        ElMessage.warning('Template content cannot be empty')
        return
      }

      saving.value = true
      try {
        const res = await adminApi.updatePrompt(voiceMode, content)
        ElMessage.success(`Template saved (${res.data.version})`)
        await loadAll()
      } catch (e: any) {
        ElMessage.error(`Failed to save: ${e.message}`)
      } finally {
        saving.value = false
      }
    }

    const handleReset = async (voiceMode: string) => {
      try {
        await ElMessageBox.confirm(
          `This will reset the "${voiceMode}" template to the built-in default. The AI Worker will use its hardcoded template.`,
          'Reset to Default',
          { confirmButtonText: 'Reset', cancelButtonText: 'Cancel', type: 'warning' },
        )
      } catch {
        return
      }

      try {
        await adminApi.resetPrompt(voiceMode)
        ElMessage.success('Template reset to default')
        await loadAll()
      } catch (e: any) {
        ElMessage.error(`Failed to reset: ${e.message}`)
      }
    }

    const handleRestoreBuffer = (voiceMode: string) => {
      const tpl = templates.value[voiceMode]
      if (tpl) {
        editBuffers.value[voiceMode] = tpl.template ?? tpl.defaultTemplate
      }
    }

    return () => (
      <div>
        <h2 style="margin-bottom: 20px;">Prompt Templates</h2>

        <ElCard style="margin-bottom: 20px;">
          <ElAlert
            title="Placeholders Reference"
            type="info"
            closable={false}
            show-icon
          >
            {{
              default: () => (
                <div style="margin-top: 8px;">
                  {PLACEHOLDERS.map((p) => (
                    <div key={p.name} style="margin-bottom: 4px;">
                      <code style="background: #f0f0f0; padding: 2px 6px; border-radius: 3px; font-size: 13px;">
                        {p.name}
                      </code>
                      <span style="margin-left: 8px; color: #666; font-size: 13px;">{p.desc}</span>
                    </div>
                  ))}
                </div>
              ),
            }}
          </ElAlert>
        </ElCard>

        <ElCard>
          <ElTabs v-model={activeTab.value}>
            {VOICE_MODES.map(({ key, label }) => {
              const tpl = templates.value[key]
              const modified = isModified(key)

              return (
                <ElTabPane key={key} label={label} name={key}>
                  <div style="margin-bottom: 16px;">
                    {tpl?.hasCustom ? (
                      <ElDescriptions border column={4} size="small">
                        <ElDescriptionsItem label="Status">
                          <ElTag type="success" size="small">Custom</ElTag>
                        </ElDescriptionsItem>
                        <ElDescriptionsItem label="Version">
                          {tpl.version ?? '-'}
                        </ElDescriptionsItem>
                        <ElDescriptionsItem label="Updated">
                          {tpl.updatedAt
                            ? new Date(tpl.updatedAt).toLocaleString()
                            : '-'}
                        </ElDescriptionsItem>
                        <ElDescriptionsItem label="Updated By">
                          {tpl.updatedBy ?? '-'}
                        </ElDescriptionsItem>
                      </ElDescriptions>
                    ) : (
                      <ElDescriptions border column={1} size="small">
                        <ElDescriptionsItem label="Status">
                          <ElTag type="info" size="small">Default (built-in)</ElTag>
                        </ElDescriptionsItem>
                      </ElDescriptions>
                    )}
                  </div>

                  {tpl?.hasCustom && tpl.defaultTemplate && (
                    <ElCollapse style="margin-bottom: 16px;">
                      <ElCollapseItem title="Default Template (reference)">
                        <pre style="white-space: pre-wrap; word-break: break-word; font-family: 'SF Mono', Monaco, monospace; font-size: 13px; background: #f5f7fa; padding: 12px; border-radius: 4px; margin: 0; color: #606266; line-height: 1.6;">
                          {tpl.defaultTemplate}
                        </pre>
                      </ElCollapseItem>
                    </ElCollapse>
                  )}

                  <ElInput
                    v-model={editBuffers.value[key]}
                    type="textarea"
                    rows={20}
                    placeholder={`Enter ${label} prompt template...\nUse placeholders like {{MODE}}, {{CONTEXT}}, etc.`}
                    style="font-family: 'SF Mono', Monaco, monospace; font-size: 13px;"
                  />

                  <ElSpace style="margin-top: 16px;">
                    <ElButton
                      type="primary"
                      loading={saving.value}
                      disabled={!modified}
                      onClick={() => handleSave(key)}
                    >
                      Save
                    </ElButton>
                    {modified && (
                      <ElButton onClick={() => handleRestoreBuffer(key)}>
                        Discard Changes
                      </ElButton>
                    )}
                    {tpl?.hasCustom && (
                      <ElButton onClick={() => handleReset(key)}>
                        Reset to Default
                      </ElButton>
                    )}
                  </ElSpace>
                </ElTabPane>
              )
            })}
          </ElTabs>
        </ElCard>
      </div>
    )
  },
})
