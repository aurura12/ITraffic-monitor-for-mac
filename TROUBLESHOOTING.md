# iTraffic 故障记录

## 2026-10-08：菜单栏绘制导致高 CPU 和耗电

状态：已修复，本机已安装验证版本 `0.3.2 (49)`。

### 现象与定位

- “使用情况”页面连续采样约 82–85% CPU；切到“曲线”后仍约 46–47%。
- 重启应用、仅保留菜单栏时仍约 50–55%，因此重启不能消除问题。
- `sample` 显示主线程反复执行 `NSStatusItem _updateReplicants`、
  `_redrawReplicantSnapshot:sourceView:`、图层快照绘制和 SwiftUI 布局。
- `nettop` 采样与数据库记录在堆栈中的开销很小。主要开销来自 macOS 26
  菜单栏快照对自定义状态项控件树的重复布局和绘制。

### 修复与验证

`MenuBarRateView` 用单个视图直接绘制文本或图标，替代 `NSStackView`、
两个 `NSTextField` 和 `NSImageView`。显示内容经过格式化后没有变化时，
跳过重绘；图标模式和暂停状态也不会因实时速率变化重新绘制。
视图继续提供辅助功能数值，并在外观变化时刷新图标颜色。

- 64 项菜单栏和仪表盘回归测试通过；Release 构建通过。
- 更新后“使用情况”页面同样的连续短采样约 0.8–0.9% CPU。
- “曲线”页面约 1–3%；之后再次复核运行版本 49，占用约 2.7–2.8%。

电池页面的进程百分比不能当作各应用消耗电量的比例。整机耗电还受其他
进程影响，CPU 修复后的续航应在实际电池供电时重新观察。
[Apple 的能耗诊断说明](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/MonitoringEnergyUsage.html)
也将持续高 CPU 列为高能耗的重要原因。

## 2026-09-06：macOS 26 菜单栏状态项不显示

状态：已解决，修复提交为 `566eb82`。

### 现象

- iTraffic 进程已经启动，但菜单栏没有显示上下行速率。
- 系统设置中的“允许在菜单栏显示 → iTraffic”是开启状态。
- 回滚到之前可以工作的代码、重启应用、重启 Control Center 后，问题仍然存在。
- 右上角看见的类似 `5.04k / 1.82k` 的数字可能来自 Stats，不能作为 iTraffic 已显示的证据。

### 诊断结论

这不是应用没有启动，也不是 `NSStatusItem` 视图布局问题。macOS 26 的 Control Center 收到 iTraffic 的显示请求后，把旧 bundle ID 对应的状态项立即放进了 blocked list。

关键日志形态：

```text
Host properties initialized; ... State(applicationItem: true, clientRequestsVisibility: true, neverClip: false)
Moving host to blocked list; (bid:com.foamzou.ITrafficMonitorForMac-...)
Starting to track blocked host; (bid:com.foamzou.ITrafficMonitorForMac-...)
```

`LSUIElement=true` 导致应用没有普通窗口和 Dock 图标，这是菜单栏应用的正常行为；不能据此判断应用没有打开。

Control Center 会按照 bundle ID 和菜单栏状态项身份保存登记状态。macOS 更新或状态迁移后，旧 ID 的 `trackedApplications/menuItemLocations` 记录可能发生残留或错配。系统设置里的开关变成 `on`，不一定能清除这条 blocked 记录。

### 最终修复

主应用 bundle ID 从：

```text
com.foamzou.ITrafficMonitorForMac
```

改为：

```text
com.foamzou.ITrafficMonitorV2
```

新 ID 被 Control Center 当作全新的状态项身份，因此不再命中旧的 blocked 记录。当前版本还保持以下内容不变：

- App Group：`group.com.foamzou.ITrafficMonitorForMac`
- 数据库目录：`~/Library/Application Support/ITraffic`
- 菜单栏显示名称：`iTraffic`

因此历史流量数据和已有 App Group 数据不会因为换 bundle ID 而改变。旧的 `ITraffic` 菜单栏登记可能仍留在系统设置中，但不影响新 ID 的运行。

以后发布版本必须继续使用 `com.foamzou.ITrafficMonitorV2`，不要再次随意修改 bundle ID。

### 以后排查步骤

1. 先确认进程：

   ```bash
   ps -axo pid=,command= | rg '/Applications/ITraffic\.app/Contents/MacOS/ITraffic$'
   ```

2. 确认实际运行包的 bundle ID：

   ```bash
   /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
     /Applications/ITraffic.app/Contents/Info.plist
   ```

3. 检查 Control Center 是否屏蔽：

   ```bash
   /usr/bin/log show --last 10m --style compact --info --debug \
     --predicate '(process == "ControlCenter" AND eventMessage CONTAINS[c] "com.foamzou.ITrafficMonitorV2")' \
     | rg 'Host properties initialized|Moving host to blocked list|Starting to track blocked host'
   ```

4. 按日志判断：

   - 没有进程：应用没有启动或启动后退出。
   - 有进程且出现 `running-active-NotVisible`：对 `LSUIElement` 菜单栏应用来说是正常的，不能单独说明被隐藏。
   - 出现 `Moving host to blocked list`：优先排查 Control Center 登记状态，不要先改菜单栏布局代码。

5. 如果新 ID 将来再次被屏蔽，先保留并备份 Control Center 状态，不要直接删除整个偏好目录。重点位置是：

   ```text
   ~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist
   ```

   重点检查其中的 `trackedApplications`，因为修改它可能影响其他菜单栏应用。

类似 macOS 26 的 Control Center blocked-list 行为也在其他菜单栏应用中被复现过：
[CodexBar issue #1440](https://github.com/steipete/CodexBar/issues/1440)
