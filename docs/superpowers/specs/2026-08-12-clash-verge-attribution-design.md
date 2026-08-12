# Clash Verge 流量归属改进设计

## 目标

尽可能把 Clash Verge/Mihomo 转发的流量归属到实际发起流量的应用；不能可靠识别时统一归入 **Clash Verge**，界面和历史中不显示 `verge-mihomo` 进程名，也不单列“未识别的代理/TUN 流量”。

## 背景与限制

`nettop -P -t external` 只报告外部接口上的 socket 所有者。开启 Clash Verge 后，外网 socket 属于特权运行的 `verge-mihomo`，故原始采样必然先把字节记到该进程。

Mihomo 的 `/connections` 接口可提供每条连接的累计上下行字节与 `metadata.sourcePort`。在系统代理模式，该端口通常对应应用到本地混合端口的 socket，可用 `lsof` 映射到 PID。TUN 模式的 source port 可能是虚拟端口；只有 Mihomo 提供有效 `processPath` 或 `process` 时才可映射到应用。当前实际 API 的这些进程字段可能为空，因此无法从 TUN 字节可靠推导出真实应用。

本次不引入 Network Extension、内容过滤器或需要苹果受限 entitlement 的机制。

## 归属规则

每一帧按以下优先级分配 `verge-mihomo` 的外网字节：

1. 已经通过连接 ID 的上一轮有效端口/PID 映射确认的连接，按 Mihomo 接口的字节增量归入该 PID。
2. 对于新连接，优先以 `sourcePort -> lsof PID` 映射；若失败，尝试 Mihomo 的 `processPath`，再尝试精确匹配运行应用的 `process` 名称。
3. 无法确认真实 PID 的连接，以及 Mihomo 自己主动建立的连接，保留在代理实体中。
4. 代理实体统一显示为 **Clash Verge**。它包含 Clash Verge 本身的流量与无法可靠分配给真实应用的转发流量。

绝不根据域名、最近活跃应用或模糊进程名猜测归属。

## 数据流与保持策略

`ProxyAttributor` 每两秒读取 Mihomo 连接表和当前 socket 表。每个连接的 `TrackedConnection` 保存该采样点已经确认的 PID；后续计算该连接增量时继续使用保存的 PID，而不要求本轮 `lsof` 再次命中。这样短暂关闭、瞬时不可见或刚被操作系统回收的应用 socket，不会导致已确认连接退回到 Clash Verge。

仅在连接首次出现且无法得到 PID 时，它后续产生的字节才留在 Clash Verge。PID 不会在连接中途被新的同端口所有者覆盖，避免端口复用导致错误归属。

二次归因仍受同一帧 `nettop` 中 Mihomo 字节上限约束；API 增量超出该上限时按方向同比缩放，保证总流量不被放大。

## 显示与历史

新增或调整显示名规范化：检测到的代理核心 PID（包括 `verge-mihomo`）显示为 `Clash Verge`。该名称用于实时列表和基于 `ProcessEntity.appKey` 的历史记录，因此未分配流量不会以原始可执行文件名产生独立历史行。

其他 Clash 变体和 Surge 保持原有名称，不受该显示规则影响。

## 测试

为独立、无 AppKit 依赖的归因决策补充单元测试，至少覆盖：

- 已确认 PID 的连接在下一次 socket 查找失败时仍继续归属原应用。
- 新连接无法识别时不被分配给任意应用。
- 未分配字节保留给代理，且该实体显示为 Clash Verge。
- 已归属字节不超过同帧代理在相应方向的 `nettop` 字节。
- 现有的 URL 安全限制和 Unix socket 响应解析继续通过。

用 Xcode 测试目标运行全量测试，并构建 Debug 配置，验证 Swift 类型检查与链接。

## 非目标

- 不能承诺 TUN 模式的逐应用 100% 归属：Mihomo 未报告 PID/路径时，macOS socket 表不能可靠恢复来源应用。
- 不根据流量目的地猜测应用。
- 不修改外部 VPN、Clash Verge 的配置或服务状态。
