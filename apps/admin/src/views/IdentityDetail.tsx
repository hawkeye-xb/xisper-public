import { defineComponent, ref, reactive, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import {
  ElCard,
  ElForm,
  ElFormItem,
  ElInput,
  ElInputNumber,
  ElSelect,
  ElOption,
  ElSwitch,
  ElButton,
  ElMessage,
  ElSkeleton,
  ElEmpty,
  ElTag,
} from 'element-plus'
import { Plus, Delete, ArrowLeft } from '@element-plus/icons-vue'
import { adminApi, type CorrectionRule, type HotwordEntry } from '../api'

export default defineComponent({
  name: 'IdentityDetail',
  props: {
    id: { type: String, required: true },
  },
  setup(props) {
    const router = useRouter()
    const loading = ref(true)
    const saving = ref(false)

    const form = reactive({
      label: '',
      description: '',
      vocabularyId: '',
      enabled: true,
      corrections: [] as CorrectionRule[],
      hotwords: [] as HotwordEntry[],
    })

    const misheardInputs = ref<Record<number, string>>({})

    const fetchIdentity = async () => {
      loading.value = true
      try {
        const res = await adminApi.getIdentity(props.id)
        const identity = res.data
        form.label = identity.label
        form.description = identity.description || ''
        form.vocabularyId = identity.vocabularyId || ''
        form.enabled = identity.enabled
        form.corrections = identity.corrections.map((r) => ({
          ...r,
          misheard: r.misheard ? [...r.misheard] : [],
        }))
        form.hotwords = (identity.hotwords || []).map((h) => ({ ...h }))
      } catch (e: any) {
        ElMessage.error(e.message || 'Failed to load identity')
      } finally {
        loading.value = false
      }
    }

    const handleSave = async () => {
      if (!form.label.trim()) {
        ElMessage.warning('Label is required')
        return
      }
      saving.value = true
      try {
        const corrections = form.corrections
          .filter((r) => r.correct.trim())
          .map((r) => ({
            correct: r.correct.trim(),
            misheard: r.misheard?.filter((m) => m.trim()) || [],
            note: r.note?.trim() || undefined,
          }))
        const hotwords = form.hotwords
          .filter((h) => h.text.trim())
          .map((h) => ({
            text: h.text.trim(),
            weight: typeof h.weight === 'number' ? h.weight : 1,
            lang: (h.lang || 'zh').trim(),
          }))
        await adminApi.updateIdentity(props.id, {
          label: form.label.trim(),
          description: form.description.trim() || undefined,
          vocabularyId: form.vocabularyId.trim(),
          enabled: form.enabled,
          corrections,
          hotwords,
        })
        ElMessage.success('Saved')
      } catch (e: any) {
        ElMessage.error(e.message || 'Failed to save')
      } finally {
        saving.value = false
      }
    }

    const addCorrection = () => {
      form.corrections.push({ correct: '', misheard: [], note: '' })
    }

    const removeCorrection = (idx: number) => {
      form.corrections.splice(idx, 1)
    }

    const addMisheard = (ruleIdx: number) => {
      const text = (misheardInputs.value[ruleIdx] || '').trim()
      if (!text) return
      if (!form.corrections[ruleIdx].misheard) {
        form.corrections[ruleIdx].misheard = []
      }
      if (!form.corrections[ruleIdx].misheard!.includes(text)) {
        form.corrections[ruleIdx].misheard!.push(text)
      }
      misheardInputs.value[ruleIdx] = ''
    }

    const removeMisheard = (ruleIdx: number, mIdx: number) => {
      form.corrections[ruleIdx].misheard?.splice(mIdx, 1)
    }

    const addHotword = () => {
      form.hotwords.push({ text: '', weight: 1, lang: 'zh' })
    }

    const removeHotword = (idx: number) => {
      form.hotwords.splice(idx, 1)
    }

    onMounted(fetchIdentity)

    return () => (
      <div style="padding: 24px; max-width: 900px;">
        <div style="display: flex; align-items: center; gap: 12px; margin-bottom: 20px;">
          <ElButton icon={ArrowLeft} onClick={() => router.push('/identities')} text>
            Back
          </ElButton>
          <h2 style="margin: 0;">Identity: {props.id}</h2>
        </div>

        {loading.value ? (
          <ElSkeleton rows={8} animated />
        ) : (
          <>
            <ElCard shadow="never" style="margin-bottom: 20px;">
              <ElForm labelPosition="top">
                <ElFormItem label="Label">
                  <ElInput v-model={form.label} placeholder="e.g. 程序员" />
                </ElFormItem>
                <ElFormItem label="Description">
                  <ElInput v-model={form.description} placeholder="Optional description" />
                </ElFormItem>
                <ElFormItem label="Vocabulary ID">
                  <ElInput v-model={form.vocabularyId} placeholder="ASR vocabulary id (optional)" />
                </ElFormItem>
                <ElFormItem label="Enabled">
                  <ElSwitch v-model={form.enabled} />
                </ElFormItem>
              </ElForm>
            </ElCard>

            <ElCard shadow="never" style="margin-bottom: 20px;">
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
                <h3 style="margin: 0;">Corrections ({form.corrections.length})</h3>
                <ElButton type="primary" icon={Plus} size="small" onClick={addCorrection}>
                  Add Correction
                </ElButton>
              </div>

              {form.corrections.length === 0 ? (
                <ElEmpty description="No corrections yet" image-size={80}>
                  {{
                    default: () => (
                      <ElButton type="primary" icon={Plus} onClick={addCorrection}>
                        Add First Correction
                      </ElButton>
                    ),
                  }}
                </ElEmpty>
              ) : (
                <div style="display: flex; flex-direction: column; gap: 16px;">
                  {form.corrections.map((rule, idx) => (
                    <div key={idx} style="border: 1px solid var(--el-border-color-lighter); border-radius: 8px; padding: 16px; position: relative;">
                      <ElButton
                        icon={Delete}
                        type="danger"
                        size="small"
                        circle
                        onClick={() => removeCorrection(idx)}
                        style="position: absolute; top: 8px; right: 8px;"
                      />
                      <ElForm labelPosition="top" style="padding-right: 40px;">
                        <div style="display: flex; gap: 12px;">
                          <ElFormItem label="Correct term" style="flex: 1;">
                            <ElInput v-model={rule.correct} placeholder="e.g. dev" />
                          </ElFormItem>
                          <ElFormItem label="Note" style="flex: 1;">
                            <ElInput v-model={rule.note} placeholder="e.g. development environment" />
                          </ElFormItem>
                        </div>
                        <ElFormItem label="Misheard variants">
                          <div style="width: 100%;">
                            <div style="display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px;">
                              {(rule.misheard || []).map((m, mIdx) => (
                                <ElTag
                                  key={mIdx}
                                  closable
                                  onClose={() => removeMisheard(idx, mIdx)}
                                  size="default"
                                >
                                  {m}
                                </ElTag>
                              ))}
                            </div>
                            <div style="display: flex; gap: 8px;">
                              <ElInput
                                modelValue={misheardInputs.value[idx] || ''}
                                onUpdate:modelValue={(v: string) => { misheardInputs.value[idx] = v }}
                                placeholder="Type a misheard variant and press Enter"
                                onKeydown={(e: KeyboardEvent) => {
                                  if (e.key === 'Enter') {
                                    e.preventDefault()
                                    addMisheard(idx)
                                  }
                                }}
                                style="flex: 1;"
                              />
                              <ElButton onClick={() => addMisheard(idx)} size="default">
                                Add
                              </ElButton>
                            </div>
                          </div>
                        </ElFormItem>
                      </ElForm>
                    </div>
                  ))}
                </div>
              )}
            </ElCard>

            <ElCard shadow="never">
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
                <h3 style="margin: 0;">Hotwords ({form.hotwords.length})</h3>
                <ElButton type="primary" icon={Plus} size="small" onClick={addHotword}>
                  Add Hotword
                </ElButton>
              </div>

              {form.hotwords.length === 0 ? (
                <ElEmpty description="No hotwords yet" image-size={80}>
                  {{
                    default: () => (
                      <ElButton type="primary" icon={Plus} onClick={addHotword}>
                        Add First Hotword
                      </ElButton>
                    ),
                  }}
                </ElEmpty>
              ) : (
                <div style="display: flex; flex-direction: column; gap: 12px;">
                  {form.hotwords.map((hw, idx) => (
                    <div key={idx} style="display: flex; gap: 8px; align-items: center;">
                      <ElInput
                        v-model={hw.text}
                        placeholder="Hotword text"
                        style="flex: 1;"
                      />
                      <ElInputNumber
                        modelValue={hw.weight}
                        onUpdate:modelValue={(v) => { hw.weight = (v ?? 1) as number }}
                        min={0}
                        max={10}
                        step={0.1}
                        controls-position="right"
                        style="width: 130px;"
                      />
                      <ElSelect v-model={hw.lang} style="width: 100px;">
                        <ElOption label="zh" value="zh" />
                        <ElOption label="en" value="en" />
                        <ElOption label="ja" value="ja" />
                        <ElOption label="auto" value="auto" />
                      </ElSelect>
                      <ElButton
                        icon={Delete}
                        type="danger"
                        size="small"
                        circle
                        onClick={() => removeHotword(idx)}
                      />
                    </div>
                  ))}
                </div>
              )}
            </ElCard>

            <div style="margin-top: 20px; display: flex; justify-content: flex-end;">
              <ElButton type="primary" size="large" loading={saving.value} onClick={handleSave}>
                Save
              </ElButton>
            </div>
          </>
        )}
      </div>
    )
  },
})
