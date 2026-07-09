# Qwen3 ASR Adapter 修复记录

## 日期：2026-03-25

## 问题

重新转写（retranscribe）场景下，35 秒音频通过 proxy burst-send（~10x 实时速度）到 Qwen3 ASR，转写结果只覆盖前 10-15 秒，后半段丢失。

## 根因分析

### 排除项

- **Qwen3 服务端无问题**：直连 DashScope 测试，burst send 35 秒音频完整转出 141 字符 / 8 段（见 `/tmp/test-qwen3-burst.py`）。
- **burst send 速率无问题**：Qwen3 服务端支持 10x 实时速度接收音频。

### 实际原因

`qwen3-asr-adapter.ts` 中两个不符合官方协议的用法，增加了 proxy 侧不必要的延迟，导致整体时序紧张：

1. **在 VAD 模式下发送了 `input_audio_buffer.commit`**
   - 官方文档明确：`commit` 仅用于手动模式（非 VAD），VAD 模式下服务端自动 commit。
   - 参考：https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-client-events

2. **`minAudioFlowBeforeFinishMs = 800` 延迟**
   - 这个延迟是为了给 `commit` 后的处理留时间，既然 `commit` 不需要，延迟也不需要。
   - 官方文档：`session.finish` 后服务端会完成当前 VAD 段的处理（stopped → committed → completed），然后才返回 `session.finished`。
   - 参考：https://help.aliyun.com/zh/model-studio/qwen-asr-realtime-interaction-process

## 改动内容

**文件：`qwen3-asr-adapter.ts`**

| 改动 | 旧代码 | 新代码 |
|------|--------|--------|
| 去掉 `minAudioFlowBeforeFinishMs` | `readonly minAudioFlowBeforeFinishMs = 800;` | 删除（属性在 types.ts 中是 optional，默认 undefined → proxy 跳过延迟） |
| `sendFinish` 去掉 `commit` | 先发 `input_audio_buffer.commit`，再发 `session.finish` | 只发 `session.finish` |

## 未改动

- `asr-proxy.ts`：无需改动，`minAudioFlowBeforeFinishMs ?? 0` 自动降级
- `alibaba-adapter.ts` / `doubao-adapter.ts`：不受影响
- `types.ts`：`minAudioFlowBeforeFinishMs` 本身是 optional，无需改动
- 客户端 `RetranscribeService.swift`：暂未改动超时（如果部署后仍有长音频超时问题再调整）

## 验证

直连 DashScope 测试脚本：`/tmp/test-qwen3-burst.py`

| 测试 | 结果 |
|------|------|
| 35s 音频，无 commit + session.finish | 141 字符，8 段，完整 ✅ |
| 35s 音频，有 commit + session.finish | 142 字符，8 段，完整 ✅ |
| 4.5s 音频，无 commit | 20 字符，2 段，完整 ✅ |

## 后续

- 部署到 dev/production 后需通过 app 端到端验证
- 如果长音频（>2 分钟）retranscribe 出现超时，需调整 `RetranscribeService.asrTimeout` 为动态值（如 `max(15, 音频时长 * 1.5)`）
