# 热力图（TrafficHeatmap）问题分析与修复方案

## 现状与问题

参考 UI（Bytetally 热力图，`docs/images/bytetally-heatmap.png`）明确要求一个完整的 **24 小时 × N 天网格**：每一天的每一个小时都有一格，零流量格子显示为接近背景色的暗蓝。当前实现只渲染数据库里存在的 `(day, hour)` 单元格，且 X/Y 轴均为数据驱动，导致以下可见问题：

### 问题 1（最严重）：热力图不是完整网格
`TrafficHeatmap.swift` 用 `Chart(cells, id: \.self)` 直接遍历查询返回的 `[HeatmapCell]`。但 `heatmap(start:end:)`（`TrafficDatabase.swift:512`）的 SQL 是 `GROUP BY day, hour`，**只返回有流量的格**。
- 选「7 Days」但只有 3 天有数据 → 只显示 3 行，而不是 7 行。
- 单日内只有若干小时有流量 → 其余小时直接是空白（没有格子），看不出是 24 列结构。
- 图表高度仍按 7 天拉伸，结果是稀疏的几块彩色矩形嵌在一片空白里，与参考 UI 完全不同。

### 问题 2：Y 轴每天一个标签在多天范围下拥挤
`AxisMarks(values: .stride(by: .day))`（`TrafficHeatmap.swift:49`）对 30 天会产生 30 个 `Text(date, format: .dateTime.month().day())`，在 260–360 px 高的卡片里重叠不可读。参考 UI 虽然也是每天一行标签，但只覆盖 7 天；30 天时需要按步长抽稀或减小字号。

### 问题 3：Y 轴标签与日格不对齐
每行单元格 `yStart` 是 `dateFromDay(day) + dayGapHours`（`+1.5h`），`yEnd` 是 `+86400 - dayGapHours`（`+22.5h`）。Y 轴 `.stride(by: .day)` 从域下界（即 `midnight+1.5h`）开始每天一个刻度，**刻度落在每行的底部边缘的间隙里**，标签与日格错位 1.5 小时。参考 UI 的标签是对齐到每天整行的。

### 问题 4：副标题「Click any hour cell to zoom in」没有对应手势
`UnifiedDashboardView.swift:157` 在 Heatmap 模式下显示该副标题，但 `TrafficHeatmap` 上没有任何点击/拖拽手势处理，是个失效的 UI 文案。

### 问题 5：`dayGapHours = 1.5h` 过大
每行只用 21 小时（21/24 ≈ 87.5%），上下各留 1.5h 间隙，行的视觉密度偏低。参考 UI 的日间间隙更细。

### 问题 6：`cornerRadius(4)` 在矮行下越界
30 天 × 260 px 高时每行约 8 px，圆角 4 px 会让格子被切得很厉害；7 天时还正常。

### 次要：死代码
`TrafficDatabase.heatmap(days:)` 和 `TrafficRecorder.heatmap(days:)`（`TrafficDatabase.swift:483`、`TrafficRecorder.swift:111`）在 commit `e59074f` 后已无人调用，但仍存在并被引用路径保留。

---

## 修复目标

让 `TrafficHeatmap` 在任意所选时间段（Today / 7 Days / 30 Days / This Month）下渲染完整的 **24 × N** 网格，行为对齐参考 UI：

1. 即使某小时/某天没有流量，也要渲染对应格子（`totalBytes = 0`），与参考 UI 一致。
2. X 轴固定 `0...24`，Y 轴固定为所选范围的完整日期区间。
3. Y 轴刻度按行排列（每天一行），多天时按需抽稀标签。
4. 每天的 `dayGap` 缩小，使行更接近全天 24h 高度。
5. 副标题文案与实际行为一致（要么实现点击，要么改成中性提示）。
6. `cornerRadius` 自适应行高，避免矮行被切坏。

---

## 实施方案

### 改动 1：在 ViewModel/Recorder 端补齐零流量格子

`TrafficHeatmap` 拿到的是「完整网格」cells，包含所选范围内全部 `(day, hour)`。由 ViewModel 在内存里把 SQL 返回的稀疏 cells 补成密集网格，DB 层无需改 SQL。

文件：`DashboardViewModel.swift` → `refreshHeatmap()`

- 取 `timeRange.interval()` 得到 `[start, end)`，以及涉及的本地日期集合（用 `Calendar.current` 从 start 到 end 的整天列表）。
- 调 `recorder.heatmap(start:end:)` 拿到稀疏 cells。
- 在主线程 closure 内构造密集数组：对每个 `day` × `hour`（0..23），若稀疏字典里有则用其值，否则 `HeatmapCell(day, hour, totalBytes: 0)`。
- `heatmapMaxBytes` 用密集数组的 max（至少为 1），保证零流量格比例恒为 0。

这样 DB 层 SQL 不动，`heatmap(start:end:)` 仍然高效。

### 改动 2：修 TrafficHeatmap 的轴域与刻度

文件：`Dashboard/TrafficHeatmap.swift`

- 显式锁定 X 轴域 `.chartXScale(domain: 0 ... 24)`，避免数据稀疏时被截断到子区间。
- Y 轴域用所选范围的首日 0 点到末日 24 点（由传入的 `startDay`/`endDay` 或直接用 cells 的 day 范围确定）。
- `dayGapHours` 从 `1.5 * 3600` 改为 `0.25 * 3600`（15 分钟间隙），让行更接近全天高度，同时 Y 轴 `.stride(by: .day)` 标签对齐到日界附近。
- Y 轴标签：≤ 8 天时 `.stride(by: .day)` 每天一个标签；> 8 天时 `.stride(by: .day, count: N)`（N 由天数决定，例如 30 天 ≈ 5–6 个标签），并用 `Text(date, format: .dateTime.month(.abbreviated).day())`。
- `cornerRadius` 按行高自适应：行高 `>= 24` 时 `4`，否则用 `min(4, 行高/3)`，或者直接移除 cornerRadius 让矮行也是直角——参考 UI 在矮行也是圆角但用 SVG/Canvas 自定义绘制，Swift Charts 难以完美适配。最低成本方案：行高 ≥ 16 px 时 `cornerRadius(4)`，否则 `cornerRadius(2)`。

### 改动 3：副标题与点击行为

`UnifiedDashboardView.swift` 的 `chartSubtitle`（line 154–158）：

- 选项 A（最小改动，符合事实）：副标题改为 `i18n.text("Hourly traffic per day")` 之类的描述性文案，去掉「zoom in」承诺。
- 选项 B（功能增强）：在 `TrafficHeatmap` 上用 `.chartOverlay { proxy in GeometryReader { ... } }` 配合 `DragGesture(minimumDistance: 0)` 捕获点击坐标，转换为 `(day, hour)` 后……但参考 UI 的「zoom」是 Pro 功能（跳到该小时的详细页），OSS 版只需展示该格子的数值即可。

我倾向于选项 A：先把渲染做对，文案去掉误导性的承诺，不引入新交互。若用户后续要做「点击格子看详情」再加手势。**请确认倾向哪个选项。**

### 改动 4：清理死代码（可选但推荐）

- 移除 `TrafficDatabase.heatmap(days:)` 与 `TrafficRecorder.heatmap(days:)`，以及 `TimeRange.heatmapDays`（如果不再被引用）。`DashboardViewModel` 现在用 `interval()` 而非 `heatmapDays`，前者已成死属性。
- 这只是清理，不影响行为。

---

## 改动文件清单

| 文件 | 改动 |
|---|---|
| `Dashboard/DashboardViewModel.swift` | `refreshHeatmap` 在主线程 closure 内补齐 0..23 × 所有日期的密集 cells |
| `Dashboard/TrafficHeatmap.swift` | 锁定 X/Y 轴域；调整 `dayGapHours`；Y 轴多天时抽稀标签；`cornerRadius` 自适应；视情况移除/替换副标题 |
| `Dashboard/UnifiedDashboardView.swift` | 副标题文案 |
| `Service/TrafficDatabase.swift` | 删除 `heatmap(days:)`（如选清理） |
| `Service/TrafficRecorder.swift` | 删除 `heatmap(days:)`（如选清理） |
| `DashboardViewModel.swift` | 删除 `TimeRange.heatmapDays`（如选清理） |

---

## 验证方式

1. 选「7 Days」+ Heatmap：应看到 7（或 8，含今日）行 × 24 列的完整网格，无数据的格子暗蓝近背景色，与参考图一致。
2. 选「30 Days」：30 行 × 24 列网格，Y 轴标签按步长抽稀到 ~5–6 个，X 轴仍是 0/3/6/.../21。
3. 选「Today」：1 行 × 24 列网格，仅当日有数据的格子高亮。
4. 选「10 Minutes」/「1 Hour」：仍显示完整 24 列（与参考 UI 一致），只有当前小时及附近有颜色。
5. 网格内无数据的天/小时格子渲染为低透明度蓝，不消失。
6. 短时长范围（< 8 天）下 Y 轴每天一个标签，标签对齐到日界。

---

## 风险与权衡

- **性能**：30 天 × 24 小时 = 720 个 RectangleMark，Swift Charts 完全能撑住（参考 commit 之前 30 天也是同样数量级）。
- **DB 兼容**：不改 SQL，老数据不变。
- **DST**：`dateFromDay` + `dayGapHours` 在跨 DST 日会有最多 1 小时误差，已存在的实现也有同样问题，本次仅缩小 gap 不引入新风险。
- **副标题选项 A vs B**：选 A 简单稳；选 B 需要额外的交互设计（详情弹窗或跳转），属于范围扩展。