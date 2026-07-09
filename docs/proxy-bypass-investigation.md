# ASR WebSocket 代理绕过调查

> 状态: **观察中** | 日期: 2026-04-10

## 问题背景

客户端使用 `URLSession` 建立 WebSocket 长连接到 ASR 服务。部分用户使用 Clash Verge 等代理工具，代理可能干扰 WebSocket 连接的稳定性。

## 当前措施

`ASRClient.swift` 中设置了 `connectionProxyDictionary = [:]`，意图绕过系统代理。

```swift
config.connectionProxyDictionary = [:]
```

## 调查结论

### `connectionProxyDictionary = [:]` 能绕过什么？

- **HTTP/SOCKS 系统代理**（System Proxy 模式）— 可以绕过 ✅
- **TUN 模式**（虚拟网卡路由劫持）— 无法绕过 ❌

### 为什么 TUN 模式无法绕过？

TUN 模式工作在**网络层（L3）**，通过创建虚拟网卡（utun）并修改系统路由表，将所有 IP 流量导向代理。这发生在应用层之下，任何 `URLSession` 级别的配置都无法绕过。

Clash Verge 连接面板中的表现：

| 源地址 | 类型 | 含义 |
|--------|------|------|
| `127.0.0.1:*` | HTTPS(tcp) | 走了 HTTP 系统代理 |
| `198.18.0.1:*` | Tun(tcp) | 走了 TUN 模式虚拟网卡 |

### TUN 模式的实际影响

TUN 模式对 WebSocket 的影响**通常比 HTTP 代理小**：
- TUN 是透明 TCP 转发，不干扰 HTTP Upgrade 握手
- 不会主动断开"空闲"连接（HTTP 代理可能会）
- 但仍可能因代理节点切换、超时策略等导致连接中断

## 诊断日志

已在 `ASRClient.swift` 的 `receiveLoop` 失败路径中添加诊断日志，记录：
- 错误域（NSURLErrorDomain 等）和错误码
- 是否为代理相关的典型错误码（如 `310 kCFErrorHTTPSProxyConnectionFailure`）
- 连接存活时间（从 connect 到断开的时长）

日志标签：`[ASR-Proxy-Diag]`，可通过 Console.app 过滤查看。

## 如果后续确认代理导致频繁断连

### 方案 A：`Network.framework` 绑定物理网卡（绕过 TUN）

```swift
import Network
let params = NWParameters.tls
if let iface = nw_interface_create_with_name("en0") {
    params.requiredInterface = iface
}
let connection = NWConnection(host: "...", port: 443, using: params)
```

**代价**：需要将 `URLSessionWebSocketTask` 替换为 `NWConnection`，手动实现 WebSocket 协议或引入第三方库。物理网卡名称因设备而异（en0/en1），需枚举判断。

### 方案 B：增强重连机制

不绕过 TUN，而是让客户端更能容忍连接中断：
- 自动重连 + 断点续传音频
- 更短的心跳检测间隔

### 方案 C：引导用户在 Clash 中配置直连规则

在 Clash 配置中添加：
```yaml
rules:
  - DOMAIN-SUFFIX,hawkeye-xb.com,DIRECT
```

**代价**：需要教育用户，不适合大规模推广。

## 监控指标

通过 `[ASR-Proxy-Diag]` 日志关注以下指标：
- 连接失败率（特别是 connect 阶段就失败的）
- 连接存活时间分布（正常应 > 录音时长）
- 是否集中在特定错误码
