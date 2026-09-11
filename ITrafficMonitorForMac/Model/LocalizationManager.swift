//
//  LocalizationManager.swift
//  ITrafficMonitorForMac
//
//  In-app language switching. All user-facing strings are looked up through
//  `text(_:)` (or the global `L()`), keyed by the English string. Views that
//  observe the manager via @EnvironmentObject re-render instantly when the
//  language changes — no app restart needed.
//

import Foundation

enum AppLanguage: String, CaseIterable {
    case system
    case zhHans = "zh-Hans"
    case en
}

final class LocalizationManager: ObservableObject {

    static let shared = LocalizationManager()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "appLanguage")
        }
    }

    /// English key -> Simplified Chinese. Keys not present fall back to
    /// English (the key itself), so missing entries degrade gracefully.
    private let zh: [String: String] = [
        // Tab labels
        "Overview": "总览",
        "Trends": "趋势",
        "Monthly Top": "月度排行",
        "Realtime": "实时",
        "Heatmap": "热力图",
        "Apps": "应用",
        "Processes": "进程",
        "Export": "导出",
        "Settings": "设置",
        "Open Dashboard": "打开仪表盘",
        "Quit": "退出",
        "Idle": "空闲",
        "Search apps": "搜索应用",

        // Overview
        "This Week": "本周",
        "This Month": "本月",
        "Month Projection": "月末预估",
        "Last 7 Days": "最近 7 天",
        "Monthly Top Apps": "本月 Top 应用",
        "No data yet — traffic is being recorded.": "暂无数据——正在记录流量",

        // Trends
        "Range": "范围",
        "No recorded traffic in this range.": "该范围内暂无流量记录",

        // Monthly Top
        "Traffic by app — this month": "本月各应用流量",
        "No data recorded this month yet.": "本月暂无流量记录",

        // Realtime
        "Total network rate — last ~10 minutes": "总网络速率——最近约 10 分钟",
        "↓ Download": "↓ 下载",
        "↑ Upload": "↑ 上传",
        "Collecting samples…": "正在采样…",

        // Ranges / granularity
        "Today": "今天",
        "Today's Usage": "今日用量",
        "7 Days": "7 天",
        "30 Days": "30 天",
        "90 Days": "90 天",
        "1 Day": "1 天",
        "Minute": "分钟",
        "Hour": "小时",
        "Day": "天",
        "Month": "月",
        "Quarter": "季度",
        "Year": "年",

        // Unified dashboard
        "Line": "曲线",
        "Usage": "使用情况",
        "Back": "返回",
        "Download": "下载",
        "Upload": "上传",
        "Download Speed": "下载速度",
        "Upload Speed": "上传速度",
        "Total Traffic": "总流量",
        "Traffic Timeline": "流量时间轴",
        "Drag to zoom any range": "拖拽可缩放任意区间",
        "Daily traffic per day": "按天呈现每日流量",
        "App Ranking": "区间内应用排行",
        "Rank updates with visible range": "随可见区间联动——框选图表即可缩小范围",
        "Name": "名称",
        "Peak": "峰值",
        "No apps match the current filter.": "没有匹配当前筛选的应用",
        "Attribution status": "归属状态",
        "Collecting proxy attribution status": "正在获取代理归属状态",
        "Direct process accounting": "直连进程统计",
        "Total traffic uses nettop bytes; apps are read directly from their sockets.": "总流量采用 nettop 字节；应用直接从自身套接字读取",
        "Proxy mapping active": "代理归属已启用",
        "Proxy mapping partly complete": "代理归属部分完成",
        "proxy connections mapped; unmatched bytes stay with the proxy.": "个代理连接已映射；无法匹配的字节保留在代理进程",
        "Proxy row not visible": "未看到代理进程行",
        "connections mapped; total remains conservative.": "个连接已映射；总量仍保持保守统计",
        "Proxy mapping temporarily paused": "代理归属暂时暂停",
        "Existing total accounting continues; new proxy bytes stay with the proxy until the API recovers.": "总量统计继续；代理 API 恢复前新增代理字节保留在代理进程",
        "Proxy API needs a secret": "代理 API 需要密钥",
        "Total traffic continues to be recorded; proxy traffic cannot be mapped until the secret is configured.": "总流量继续记录；配置密钥前无法映射代理流量",
        // Usage bar chart
        "Traffic Usage": "流量使用",
        "Linear": "实际比例",
        "Log": "对数比例",
        "Daily usage": "每日使用情况",
        "Monthly usage": "每月使用情况",
        "Quarterly usage": "每季度使用情况",
        "Yearly usage": "每年使用情况",
        "No recorded traffic yet.": "暂无流量记录",

        // App detail
        "Last 30 Days": "最近 30 天",
        "30d ↓ / ↑": "30天 下载/上传",
        "Daily Traffic — Last 30 Days": "每日流量——最近 30 天",
        "Daily Breakdown — Last 14 Days": "每日明细——最近 14 天",
        "Date": "日期",
        "Total": "总量",
        "No active traffic": "当前无流量",

        // Export
        "Export Traffic Data": "导出流量数据",
        "Format": "格式",
        "Granularity": "粒度",
        "Minute granularity is limited to 1 day to keep the file size reasonable.": "分钟粒度限制在 1 天以内，以保证文件体积合理",
        "Cancel": "取消",
        "Exporting…": "导出中…",
        "Export Failed": "导出失败",
        "OK": "确定",

        // Settings
        "Language": "语言",
        "Appearance": "外观",
        "Follow System": "跟随系统",
        "Light": "浅色",
        "Dark": "深色",
        "Launch at login": "开机自动启动",
        "Launch at login failed": "开机自动启动设置失败",
        "Version": "版本",

        // Proxy attribution
        "Proxy attribution": "代理归属",
        "Enable proxy attribution": "启用代理归属",
        "Foreground App Fallback": "前台应用兜底",
        "Attribute residual proxied traffic to the frontmost app": "把无法归属的代理流量兜底给当前前台应用",
        "Proxy type": "代理类型",
        "Auto detect": "自动检测",
        "Clash": "Clash",
        "Surge": "Surge",
        "Off": "关闭",
        "API base URL": "API 地址",
        "Secret": "密钥",
        "Proxy detected": "已检测到代理",
        "No proxy detected": "未检测到代理",
        "Secret required": "需要密钥",
        "Redetect": "重新检测",
        "Diagnostic Logs": "诊断日志",
        "Show in Finder": "在 Finder 中显示",
        "Clear": "清空",
        "Proxy attribution diagnostics are retained locally (up to 16 MB).": "代理归属诊断日志仅保存在本机（最多 16 MB）。",

        "Traffic metric": "流量口径",
        "Totals use nettop non-loopback interface socket traffic; this is not a physical Wi-Fi/Ethernet counter.": "总量采用 nettop 非回环接口 socket 流量，不等同于物理 Wi-Fi/有线网卡计数",
        "Only same-frame confirmed proxy bytes are reassigned; unmatched bytes stay with Clash.": "仅重新归属同一采样帧内已确认的代理字节；无法确认的字节保留在 Clash",

        // Sampling diagnostics
        "Sampling diagnostics": "采样诊断",
        "Last nettop sample": "最近一次 nettop 采样",
        "nettop delta": "nettop 增量",
        "Physical interface delta": "物理网卡增量",
        "VPN utun delta": "VPN utun 增量",
        "Reference counters are for comparison only and are not added to historical totals.": "参考计数仅用于对比，不会加入历史总量",
        "Waiting for nettop sample": "等待 nettop 采样",
        "nettop sampling active": "nettop 采样正常",
        "nettop sampling restarting": "nettop 采样重启中",
        "Skipped nettop rows": "已跳过的 nettop 行",

        // Network Extension / calibration status
        "Authorizing…": "授权中…",
        "Enabled": "已启用",
        "Fallback": "回退模式",
        "Error": "错误",
        "Waiting": "等待中",
        "Active": "已激活",
        "Unavailable": "不可用",
    ]

    private init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        language = newLanguage
    }

    /// Locale used for dates / charts. Never nil — system maps to the real
    /// current locale so `.environment(\.locale, ...)` can always be applied.
    var locale: Locale {
        switch language {
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .en: return Locale(identifier: "en_US")
        case .system: return Locale.current
        }
    }

    /// Resolve a UI string in the active language.
    func text(_ key: String) -> String {
        let useChinese = language == .zhHans
            || (language == .system && Locale.current.language.languageCode?.identifier == "zh")
        return useChinese ? (zh[key] ?? key) : key
    }
}

/// Global shortcut for places without access to the environment object
/// (AppDelegate window titles etc.). Reads the shared singleton.
func L(_ key: String) -> String {
    LocalizationManager.shared.text(key)
}
