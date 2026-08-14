# 当前进度：VPN 按 App 流量统计

更新时间：2026-08-14

## 目标

精确显示每个 App 通过 VPN/代理使用的上传、下载和总流量，并继续保留系统总流量统计。

## 当前结论

- 系统总流量统计可以继续使用，当前仍以 `nettop` 采集为主。
- 现有项目已经加入 Network Extension Content Filter 的按 App 统计实现。
- Network Extension 代码已经完成编译和单元测试，但尚未完成真实安装、启用和 VPN 流量验证。
- 原因不是代码缺失，而是当前 Mac 没有 Apple Developer Team、开发证书和对应签名授权。
- 用户目前不打算购买每年 99 美元的 Apple Developer Program，因此项目暂时停在“代码完成、运行验证待授权”的状态。
- 免费方案已继续增强：加入 `nettop + 代理连接表 + utun 总量参考` 的保守校准层，不需要 Apple Developer Program。
- 免费运行配置已修复：主 App 不再引用 Network Extension entitlements，因此可以使用 Xcode 的 `Sign to Run Locally` 运行；Network Extension entitlements 文件仍保留给以后有 Team 时使用。

## 已完成内容

### Network Extension 方案

- 添加 Data Provider 和 Control Provider 两个扩展。
- 通过 App Group 在主 App 与扩展之间共享统计结果。
- 记录连接所属 App、上传字节数、下载字节数和连接数。
- 对无法识别的连接归入 `Unattributed VPN`。
- 主 App 增加 `TrafficFilterManager`，负责加载、保存、启用过滤器配置和读取统计结果。
- 增加统计游标、JSONL 共享输出和聚合逻辑，避免重复记录。
- Network Extension 未产出数据时继续使用 `nettop`，避免界面完全没有数据。
- 设置页面增加 Network Extension 状态、最近报告和重新加载入口。

### 免费校准方案

- 添加 `UTunTrafficSampler`，在独立后台队列读取 `netstat -ib` 中的 `utun*` 接口累计字节。
- 添加 `FreeAttributionCalibrator`，将能解释的流量保留给对应 App。
- 只有当 `utun` 参考总量高于当前已归属总量时，才把差额放入 `Unattributed VPN`。
- 当计数器回退、采样不可用或参考总量较低时，不扣减已有 App 数据，继续使用原有 `nettop` 结果。
- 设置页面增加免费校准状态，显示 `utun` 参考是否可用。
- `Network` 使用校准后的实体和总量更新实时显示，同时保留旧的无校准回退路径。

### 测试与检查

- `TrafficFilterTests`：14 个测试通过。
- 原有 `TrafficBarHoverTests`：35 个测试通过。
- 总计：49 个测试通过，0 个失败。
- 无签名 `build-for-testing` 通过。
- Entitlements 和 Info.plist 的 `plutil` 检查通过。
- `git diff --check` 通过。

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
- 无法匹配的流量应显示为“未归属”，不要强行分配给某个 App。

总流量也可能与 VPN 服务器端看到的流量存在差异，因为两边的统计口径可能包含不同的协议开销、DNS、重传和隧道数据。

## 以后继续时的建议顺序

### 方案 A：继续免费方案（当前推荐）

1. 保持现有 Network Extension 代码不删除，作为以后恢复的基础。
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
- `ITrafficMonitorForMac/Service/UTunTrafficSampler.swift`：免费 VPN 总量参考采样。
- `ITrafficMonitorForMac/Service/FreeAttributionCalibrator.swift`：保守的差额归属和可信度。
- `ITrafficMonitorForMac/NetworkFilter/`：Network Extension 两个 Provider 及共享代码。
- `ITrafficMonitorForMacTests/TrafficFilterTests.swift`：新增统计逻辑测试。
- `project.yml`：XcodeGen 工程配置。
- `docs/superpowers/specs/2026-08-14-network-extension-traffic-attribution-design.md`：设计说明。
- `docs/superpowers/plans/2026-08-14-network-extension-traffic-attribution.md`：实施计划。

## 注意事项

- 不要把“无签名编译通过”表述成“Network Extension 已经运行正常”。
- 在没有真实签名和 VPN 测试前，不要宣称按 App 的 VPN 流量已经精确。
- 重新运行 `xcodegen generate --spec project.yml` 后，要检查 entitlements 是否仍然存在。
- 当前改动尚未提交 Git commit；继续开发前先查看 `git status`，避免覆盖已有修改。
- `utun` 采样需要 macOS 实际返回接口计数；如果系统拒绝 `netstat -ib`，界面会显示不可用并自动回退。
- 目前仍未在真实 VPN 流量下完成端到端对账，因此不能宣称每个 App 已达到 100% 精确。
- 如果重新运行 `xcodegen generate --spec project.yml`，主 App target 不应重新出现 `CODE_SIGN_ENTITLEMENTS`；只有两个可选的 Network Extension target 保留签名配置。
