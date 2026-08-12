# Clash Verge 归因恢复设计

## 目标

让 iTraffic 能稳定发现当前运行的 Clash Verge/Mihomo，并在系统代理模式下把代理出口流量归属回真实应用；TUN 模式缺少进程元数据时，安全地保留为 Clash Verge，不猜测应用归属。

## 方案

`ProxyAttributor` 保留现有两秒轮询架构，但把“端点发现、连接抓取、PID 归因、状态诊断”分开处理：

1. 端点发现同时覆盖 Clash Verge 的核心 Unix socket、TCP external-controller 和配置/PID 文件。
2. Unix socket 请求必须区分连接失败、HTTP 错误、认证失败和空连接表；空表表示代理已发现，不应降级成未检测到。
3. 核心 PID 优先使用 socket 的 `lsof` 结果，失败时读取 `clash-verge-service.core.json`，并允许当前用户无法检查 root 进程。
4. 归因优先使用已确认的连接 PID，其次使用源端口映射，最后使用 Mihomo 的进程路径/名称；没有证据时保留在 Clash Verge。
5. 设置页继续显示简洁状态，但内部状态保留最近一次诊断信息，便于判断 API、权限和 TUN 限制。

## 边界

- 不引入 Network Extension，不修改 VPN 或代理配置。
- 不根据域名、最近活跃应用或模糊名称推断 PID。
- 不把控制 API 的字节重复计入 nettop；仍以 nettop 代理实体字节作为可归属上限。
- 保留已有工作区中与本功能无关的用户改动。

## 验收

- Clash Verge socket 存在但当前无连接时，状态为已检测到 Clash Verge，而不是未检测到代理。
- API 失败时能够得到稳定、可测试的失败分类。
- 已确认 PID 的连接在后续 `lsof` 暂时失败时仍继续归属原应用。
- 未确认 PID 的 TUN 流量不会分配给随机应用。
- 现有测试和 macOS 构建通过。
