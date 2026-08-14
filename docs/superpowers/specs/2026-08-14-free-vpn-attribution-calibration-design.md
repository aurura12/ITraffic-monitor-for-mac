# 免费 VPN 流量归属校准设计

## 目标

在不依赖 Apple Developer Program 和 Network Extension 签名的前提下，提高 VPN/代理场景下的按 App 流量归属准确度，同时保证系统总量不会被重复计算。

## 方案

保留现有 `nettop` 采集和 Mihomo/Clash/Surge 连接归属逻辑，并增加一个独立的校准层：

1. `nettop` 提供当前进程的外部接口流量。
2. 代理连接表提供原始 App 的连接和字节增量。
3. `utun` 接口计数器提供 VPN 隧道的独立总量参考。
4. 校准层只在数据方向和时间窗口可比较时，将无法解释的差额放入 `Unattributed VPN`；不把差额强行分给某个 App。
5. 当 `utun` 数据缺失、计数器回退或与当前采样明显不一致时，保留原有 `nettop` 结果并报告 `mismatch`，不改变已有数据。

## 设计边界

- 这是免费条件下的最佳努力归属，不宣称等同于 Network Extension 的精确 per-App VPN 统计。
- `utun` 只作为总量校准参考，不承担 App 身份识别。
- 采样器运行在独立队列，不能阻塞 `NettopRunner`。
- 所有解析和校准规则使用纯函数测试。
- 现有代理归属逻辑继续作为第一层，不重写已验证的连接映射代码。

## 数据流

```text
nettop frame ──┐
               ├─ ProxyAttributor ── FreeAttributionCalibrator ── recorder/UI
proxy API ─────┘                    ↑
                                    │
                             utun counter sampler
```

## 失败处理

- 无 `utun`：继续使用现有 `nettop + proxy attribution`。
- `utun` 计数器回退：丢弃本次 delta，等待下一次有效样本。
- 校准差额为负：不扣减已有 App 数据，标记为不一致。
- 无法映射的连接：保留在 `Unattributed VPN`，并继续写入诊断日志。

## 验收标准

- 能正确解析 `netstat -ib` 中的 `utun*` 入站/出站字节。
- 能处理接口出现、消失、计数器回退和多接口合计。
- 在参考总量大于已归属总量时，差额只进入 `Unattributed VPN`。
- 在参考总量小于已归属总量时，不产生负数、不修改已有归属。
- 现有测试继续通过。
