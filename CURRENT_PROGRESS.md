# 当前进度：纯总量流量统计

更新时间：2026-10-28

## 目标

统计并展示本机总上传 / 下载流量与实时速率，保留历史记录与仪表盘；**不再按 App 拆分**。

## 当前结论

- 应用只做总量统计：每帧取 `nettop` 上下行字节之和。
- 已彻底移除 per-App 链路：代理 / VPN 归属、进程身份解析、Network Extension，以及 `app_traffic` / `apps` / `sample_allocations` 存储全部删除。
- 历史数据已**无损**迁移为纯总量：新增 `traffic_totals`，一次性把旧的按 App 桶按 `bucket_start` 求和折叠过去，`PRAGMA user_version` 升到 2。
- 数据库只保留总量：`traffic_samples`（逐帧账本，幂等）+ `traffic_totals`（分钟桶）+ `archived_samples`（去重墓碑）+ `accounted_traffic` 视图。
- 总量统计不需要 Network Extension，因此「无开发者签名」不再是本功能的限制。

## 已完成内容

### CPU 与耗电优化

- 实时速率改为一帧一次发布，上下行同步更新，相同速率跳过通知。
- 仪表盘仅两个速度卡片订阅实时速率，历史图表与控件不再每两秒整体更新；删除没有图表消费者的实时速率环形缓冲区。
- 仪表盘与设置窗口关闭、最小化或完全被遮挡时，停止实时界面观察；仪表盘刷新定时器随内容移除而取消，重新显示时立即刷新。
- 菜单栏弹窗仅在显示期间定时查询当日总量，关闭时取消定时器。
- 使用情况页面的图表分配明确的可用高度，图表标题与分段控件保持固有高度，减少滚动区中的重复布局。
- `nettop` 仍每两秒采样，逐帧入库和历史汇总逻辑保持原有精度。
- `nettop` 退出或起不来时按指数退避重启（0.5s 起、翻倍、30s 封顶），连续失败 4 次后设置页显示「采样失败、仍在重试」，收到帧即恢复；不再每 0.5 秒无限重启。

### 界面

- 菜单栏弹窗每次显示前按内容重新测量高度（带最小高度兜底），切换语言或暂停态文本变化后不再裁切按钮。
- 去掉弹窗的 5 秒自动关闭：点外部或切换 App 仍会关闭，但不再在阅读时被强制关掉。
- 设置页新增「存储」：数据库打不开或缺少 `accounted_traffic` 视图时显示「数据库不可用」+ sqlite 原始原因，不再只是历史全为 0。

### 数据层

- `traffic_totals(bucket_start PK, day, hour, in_bytes, out_bytes, sample_count)` 取代 `app_traffic`。
- 一次性压缩（`user_version` 2 → 3）：`DROP TABLE` 只把旧 per-App 页放进 freelist，不会缩小文件；`compactFreePagesIfNeeded()` 在折叠完成且空闲页 ≥ 256 页（1 MB）且 ≥ 5% 时执行一次 `VACUUM`，成功后才置 3。生产库实测 119 MB → 约 20 MB。
- 日志统一走 `os.Logger`（`Log.swift`），不再用 `print()`：GUI 启动时 stdout 被丢弃，`update.sh --telemetry` 的 subsystem 也已对齐当前 bundle id。
- `accounted_traffic` 视图直接读 `traffic_totals` + 未汇总的 `traffic_samples.raw_*`，已无 `app_key`。
- rollup 改为按 bucket 聚合原始总量，不再有 allocation 维度。
- 守恒变成结构性：`traffic_samples.raw_*` 是唯一字节来源，写入时只做非负校验。
- 查询失败（SQLite 无法 prepare）与成功路径一致，回调统一走主队列；此前 `dailyTraffic` / `trafficSeries` 会在数据库队列上回调，调用方从后台线程写 `@Published`。
- 小时粒度导出的时间点改为本地整点（交给 `Calendar` 解析），不再用「当日零点 + hour×3600」，否则夏令时切换当天该小时之后的行会整体偏移 1 小时。

### 迁移

- `user_version = 2` 门控的一次性迁移：先把 `app_traffic` 按 bucket 折叠进 `traffic_totals`（`SUM(MAX(0,·))` 吸收旧的负值 clamp，`NOT EXISTS` 保证按 bucket 幂等），再删除 per-App 表；单事务 + `VACUUM INTO` 备份，失败回滚、下次启动重试。
- 已在生产库副本上验证**逐字节无损**（折叠前后总量完全一致）。

### 删除

- 归属：`ProxyAttributor`、`FreeAttributionCalibrator`、Clash/Surge 轮询与 lsof。
- 身份：`getAppInfo` / `owningAppForProcess` / WebKit 归属 / `HelperAttributionRegistry` / `iconForAppKey` / `ProcessEntity`。
- Network Extension：`NetworkFilter/`（含 Shared）以及 `TrafficFilterManager` / `TrafficFilterStatsStore`。
- 诊断采样：`UTunTrafficSampler` 与设置页 Physical / VPN delta 两行（保留 nettop 采样状态与「解析失败行数」）。
- UI：per-App 排行榜、应用详情页、菜单栏「最忙 App」、导出中的 App 字段。
- 配置清理：启动时删除 `proxyAttribution*` UserDefaults 与遗留的 `proxy-diagnostics.log`。

### 测试

- 用例数 129 → 79（删除了归属 / 身份 / NetworkFilter 用例）。
- `TrafficRollupTests` 重写为纯总量 + 迁移测试（折叠并删表置 2、逐 bucket 幂等、新库无 legacy 表、已 v2 重开为 no-op、总量查询透明）。

## 当前限制

- `nettop -t external` 统计所有非 loopback 接口，因此**包含局域网 / 组播流量**（如 mDNSResponder、netbiosd），并非仅 WAN。
- 解析失败的行会少计，已在设置页「解析失败行数」暴露。

## 重要文件

- `Service/NettopRunner.swift`：nettop 采集。
- `Network.swift`：帧 → 总量。
- `Service/TrafficRecorder.swift`：写入与 rollup 触发。
- `Service/TrafficDatabase.swift`：schema、迁移、查询。
- `Model/StatusDataModel.swift`：采样诊断。
- `Dashboard/`：仪表盘 / 设置 / 导出。
- `docs/superpowers/`：历史设计文档，其中多数描述的是**已移除**的 per-App / VPN 归属方案，仅供存档。
