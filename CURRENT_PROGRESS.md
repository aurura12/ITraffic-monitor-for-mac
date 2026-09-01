# 当前进度：VPN 按 App 流量统计

更新时间：2026-09-01

## 目标

精确显示每个 App 通过 VPN/代理使用的上传、下载和总流量，并继续保留系统总流量统计。

## 当前结论

- 系统总流量统计可以继续使用，当前仍以 `nettop` 采集为主。
- Network Extension Content Filter 的按 App 统计源码仍保留，但不属于默认免费工程。
- 默认免费构建使用 `nettop -t external` 作为唯一总量来源；不会编译、安装或启用未签名的 Network Extension。
- 当前 Mac 没有 Apple Developer Team、开发证书和对应签名授权，因此无法把 VPN 隧道内的每个 App 字节数做成精确统计。
- 代理 API 现在只提供归属声明：只在同一 nettop 采样帧的 Clash 原始预算内转移，无法确认的字节保留在 Clash。
- 免费归属链路已加强：端口缓存校验进程启动时间，连接 ID 复用时校验源端口和协议，代理未报告协议且 TCP/UDP 归属不唯一时拒绝猜测。
- 主面板显示当前归属状态和代理连接映射覆盖率；总量继续明确使用 nettop 原始字节，应用归属保持最佳努力口径。
- 历史数据按逐帧采样账本持久化，重复采样提交幂等，当前分钟可直接查询。
- 免费运行配置已修复：主 App 不再引用 Network Extension entitlements，因此可以使用 Xcode 的 `Sign to Run Locally` 运行；Network Extension entitlements 文件仍保留给以后有 Team 时使用。

## 已完成内容

### Network Extension 方案（保留源码，暂不纳入免费构建）

- 添加 Data Provider 和 Control Provider 两个扩展。
- 通过 App Group 在主 App 与扩展之间共享统计结果。
- 记录连接所属 App、上传字节数、下载字节数和连接数。
- 对无法识别的连接归入 `Clash Verge`（没有独立的未归属 VPN 桶）。
- 主 App 保留 `TrafficFilterManager`，作为以后有 Team 时接回扩展的基础；默认启动流程不会调用它。
- 增加统计游标、JSONL 共享输出和聚合逻辑，避免重复记录。
- Network Extension 统计流只保留为身份/状态诊断，不写入历史账本；历史始终由 `nettop` 采样产生。
- 设置页面保留 Network Extension 状态相关代码，默认免费构建不宣称这些状态代表扩展已安装或已启用。

### 守恒归属方案

- `Network` 记录每个 nettop 帧的原始上下行字节；代理归属只能从该帧的 Clash 行转移同量字节。
- 移除正式链路中的 utun 补差、比例分摊、跨帧 proxy debt 和前台应用兜底。
- `traffic_samples` 与 `sample_allocations` 在一个事务中提交，最终 App 总量加 Clash 剩余严格等于原始 nettop 总量。

### 测试与检查

- 新增守恒结算、无代理行保留原始字节、采样账本幂等测试。
- 无签名 `build-for-testing` 通过。
- Entitlements 和 Info.plist 的 `plutil` 检查通过。
- `git diff --check` 通过。
- 2026-09-01：macOS arm64 构建通过；单元测试 71/71 通过。

## 当前限制

### 未完成

还没有完成以下真实运行验证：

1. 使用 Apple Developer Team 对 App 和两个扩展签名。
2. 安装并启用 Network Extension Content Filter。
3. 开启 VPN/代理后访问网络。
4. 对比每个 App 的统计值与 VPN/代理端记录。
5. 验证重启、断网、切换代理和扩展异常时的恢复行为。

### 免费方案能做到什么

不购买开发者账号时，可以继续使用 `nettop + Mihomo` 的兼容方案：

- 总流量可以继续显示。
- 普通直连流量通常可以按进程统计。
- VPN/代理流量只能尽量归属到 App，不能保证每个 App 的 VPN 字节数 100% 精确。
- 无法匹配的流量保留在 Clash，不按比例分摊，也不强行分配给前台 App。

总流量也可能与 VPN 服务器端看到的流量存在差异，因为两边的统计口径可能包含不同的协议开销、DNS、重传和隧道数据。

## 以后继续时的建议顺序

### 方案 A：继续免费方案（当前推荐）

1. 保持现有 Network Extension 代码不删除；默认 `project.yml` 不编译两个扩展 target，作为以后恢复的基础。
2. 优先完善 `nettop` 和 Mihomo 日志关联。
3. 在 UI 中明确区分“精确统计”和“估算统计”。
4. 增加数据来源标识，例如：`nettop`、`Network Extension`、`未归属`。
5. 用多个 App 同时连接 VPN，检查总量与各 App 估算值之间的关系。

### 方案 B：以后获得 Team 后完成精确方案

1. 加入个人 Apple Developer Program，或让公司 Team 邀请当前 Apple ID。
2. 在 Xcode 中选择正确的 Team，确认 Network Extensions capability。
3. 检查 App、Data Provider、Control Provider 的 Bundle ID、App Group 和 entitlements。
4. 重新签名、安装并启用过滤器。
5. 用可控测试流量验证上传、下载、重启恢复和异常恢复。
6. 再决定是否将 Network Extension 方案作为默认数据源。

## 重要文件

- `ITrafficMonitorForMac/Service/TrafficFilterManager.swift`：过滤器配置和统计读取。
- `ITrafficMonitorForMac/Service/TrafficFilterStatsStore.swift`：共享统计读取和游标。
- `ITrafficMonitorForMac/Service/TrafficRecorder.swift`：流量写入入口。
- `ITrafficMonitorForMac/Service/NettopRunner.swift`：当前免费方案的重要数据来源。
- `ITrafficMonitorForMac/Service/UTunTrafficSampler.swift`：仅保留为可选诊断采样，不参与历史总量。
- `ITrafficMonitorForMac/NetworkFilter/`：Network Extension 两个 Provider 及共享代码。
- `ITrafficMonitorForMacTests/TrafficFilterTests.swift`：新增统计逻辑测试。
- `project.yml`：XcodeGen 工程配置。
- `docs/superpowers/specs/2026-08-14-network-extension-traffic-attribution-design.md`：设计说明。
- `docs/superpowers/plans/2026-08-14-network-extension-traffic-attribution.md`：实施计划。

## 注意事项

- 不要把“无签名编译通过”表述成“Network Extension 已经运行正常”。
- 在没有真实签名和 VPN 测试前，不要宣称按 App 的 VPN 流量已经精确。
- 重新运行 `xcodegen generate --spec project.yml` 后，要检查默认工程不包含两个 Network Extension target，且主 App 不出现 `CODE_SIGN_ENTITLEMENTS`。
- 设计基线已提交 Git；代码改造完成前仍需查看最终 `git status`，避免覆盖已有修改。
- 目前仍未在真实 VPN 流量下完成端到端对账，因此只能宣称总量守恒；不能宣称每个 App 已达到 100% 精确。
- 如果以后恢复精确方案，需要重新加入两个 Network Extension target、App 的嵌入关系、签名配置和真实安装启用流程；当前免费工程不会自动完成这些步骤。
