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
        "Traffic Timeline": "流量时间轴",
        "Drag to zoom any range": "拖拽可缩放任意区间",
        "Daily traffic per day": "按天呈现每日流量",
        "App Ranking": "区间内应用排行",
        "Rank updates with visible range": "随可见区间联动——框选图表即可缩小范围",
        "Name": "名称",
        "Peak": "峰值",
        "No apps match the current filter.": "没有匹配当前筛选的应用",
        "Refresh": "手动",
        "All Networks": "全部网络",

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

        // Proxy attribution
        "Proxy attribution": "代理归属",
        "Enable proxy attribution": "启用代理归属",
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
