# Network Extension 逐 App VPN 流量统计设计

## 目标

让 iTraffic 在 Clash Verge 的系统代理模式和 TUN 模式下，按真实源 App 统计 VPN 流量的上下行字节，并把统计结果写入现有历史数据库。

第一阶段只观察和统计，不拦截、不修改 Clash Verge、VPN、TUN 或系统代理配置。现有 `ProxyAttributor` 保留为兼容方案和总量校验来源，Network Extension 成为逐 App 归属的主要来源。

## 当前边界

当前工程只有主 App 和单元测试 target，部署目标为 macOS 14.0，没有 Network Extension target，主 App entitlements 为空。当前代理归属依赖 Mihomo `/connections`、source port、`lsof` 和 `nettop`，日志已经显示 TUN 场景存在 unmapped connections 和过期 pending credits。因此该方案不能承诺逐 App 精确归属。

## 方案选择

### 方案 A：Network Content Filter（采用）

新增 Content Filter Data Provider 和 Control Provider。Data Provider 接收每条网络 flow，读取 `NEFilterFlow.sourceAppIdentifier`，对 flow 返回 allow，并请求统计报告。Control Provider 接收 `NEFilterReport` 的上下行字节和源 App 信息，按 App 聚合后写入共享 App Group 容器。主 App 定时读取聚合结果并写入 `TrafficDatabase`。

该方案不接管 VPN 数据通道，适合继续使用 Clash Verge 的系统代理和 TUN 模式。它使用系统提供的源 App 标识，不再通过端口和 PID 反推归属。

### 方案 B：继续增强 Mihomo 映射

保留当前 `/connections` + `lsof` + `nettop` 方案并继续改善超时、协议识别和缓存。该方案改动较小，但 TUN 模式仍受 source port、进程生命周期和控制器元数据限制，不能满足精确逐 App 统计目标。

### 方案 C：接管 VPN 数据通道

实现 `NEPacketTunnelProvider` 或透明代理，自己读取虚拟接口或代理 flow 并统计。该方案需要替代或串联 Clash Verge 的 VPN 通道，会改变现有网络行为，范围和风险都明显更大，暂不采用。

## 架构

```text
Clash Verge / 系统代理 / TUN / 直连
                ↓
       macOS Network Extension
        Data Provider: 识别 flow
        Control Provider: 统计报告
                ↓
          App Group 共享存储
                ↓
       主 App TrafficFilterManager
                ↓
          TrafficDatabase
```

### Data Provider

新增 `TrafficFilterDataProvider`，继承 `NEFilterDataProvider`。

- 在 `handleNewFlow` 中读取 `sourceAppIdentifier`、`sourceAppUniqueIdentifier`、flow identifier 和可用的目标/协议元数据。
- 为每个 flow 建立短生命周期的 flow-to-app 映射。
- 返回 allow，不阻断或改变任何连接。
- 设置 `shouldReport = true`。
- 设置统计报告频率为中或高，第一版优先验证 high 的系统开销和数据完整性。
- 不直接访问网络、不写主 App 数据库、不传输原始网络内容。

### Control Provider

新增 `TrafficFilterControlProvider`，接收 `NEFilterReport`。

- 读取 report 的 flow 源 App 标识。
- 累加 `bytesInboundCount` 和 `bytesOutboundCount`。
- 按稳定 App Key 聚合，而不是按进程 PID 聚合。
- 处理 statistics、flow closed 和 provider 重启造成的重复/断点问题。
- 通过 App Group 共享容器输出版本化的统计记录。

### 主 App

新增 `TrafficFilterManager` 和 `TrafficFilterStatsStore`。

- 使用 `NEFilterManager` 加载和保存 Filter 配置。
- 首次启用时引导用户完成系统授权。
- 配置 `filterSockets = true`，第一版不启用原始 packet filtering；macOS 当前不支持 `filterBrowsers`，浏览器流量通过 socket filtering 验证。
- 定时读取共享统计记录，转换为现有 recorder/database 使用的增量格式。
- 显示 Filter 状态、最近报告时间、已识别 App 数量和总量差异。
- Filter 不可用时继续使用当前 `ProxyAttributor`，并明确标记为 fallback 模式。

## 数据模型

共享记录使用版本化、可幂等消费的格式：

```json
{
  "schemaVersion": 1,
  "sequence": 1234,
  "timestamp": 1786680000,
  "appKey": "com.google.Chrome",
  "displayName": "Google Chrome",
  "inBytes": 12582912,
  "outBytes": 524288,
  "flowCount": 8
}
```

主 App 记录最后消费的 sequence，避免扩展重启或主 App 重启时重复写入。未提供 source App 的 flow 不猜测归属，进入 `Unattributed VPN` 汇总项，并从诊断数据中单独统计。

## 总量校验

每个采样窗口记录三组数据：

```text
Network Extension total
≈ attributed app total + unattributed total
≈ nettop interface total
```

允许小范围差异，用于覆盖报告批次、连接关闭和系统统计粒度造成的边界误差。超过阈值时记录诊断事件，不将差额静默分配给 Clash Verge 或随机 App。

## 授权与发布约束

- 主 App 和扩展需要 Network Extension capability。
- 需要为 App Group 创建并配置一致的 entitlement。
- Content Filter Data Provider 在 macOS 上按 System Extension 方式部署。
- Debug 版本先使用本地签名验证授权流程；发布版本需要正确的 Developer ID、Network Extension entitlement、notarization 和系统扩展安装流程。
- 首次启用必须提供清晰的用户说明，明确该扩展用于统计网络字节，不拦截内容。

## 验证计划

第一阶段不接入正式历史数据库，先增加诊断面板和测试输出，覆盖：

1. Clash Verge 系统代理模式。
2. Clash Verge TUN 模式。
3. Chrome、Safari、VS Code 的 TCP 流量。
4. UDP/QUIC 流量。
5. App 退出时仍存在的 flow。
6. Clash Verge 重启和 Network Extension 重启。
7. 多个 `utun` 接口同时存在。
8. Filter 报告与 `nettop` 总量对账。

只有 TUN 模式下能稳定获得源 App 标识，并且总量差异在可解释范围内，才启用正式历史写入。

## 非目标

- 不替换 Clash Verge 的 VPN 实现。
- 不修改 Clash Verge 配置或代理规则。
- 不读取或上传网络内容。
- 不保证内核级、系统守护进程或无源 App 标识流量可以归属到具体第三方 App。
- 不在第一阶段实现网站/域名级统计。
