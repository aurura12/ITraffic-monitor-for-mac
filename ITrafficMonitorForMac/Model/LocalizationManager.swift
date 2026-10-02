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
        "Heatmap": "热力图",
        "Export": "导出",
        "Settings": "设置",
        "Open Dashboard": "打开仪表盘",
        "Quit": "退出",

        // Status-item context menu
        "Pause Monitoring": "暂停监控",
        "Resume Monitoring": "继续监控",
        "Paused": "已暂停",
        "Total": "总量",

        // Trends
        "Range": "范围",
        "No recorded traffic in this range.": "该范围内暂无流量记录",

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
        "Download": "下载",
        "Upload": "上传",
        "Download Speed": "下载速度",
        "Upload Speed": "上传速度",
        "Total Traffic": "总流量",
        "No traffic": "无流量",
        "Less": "少",
        "More": "多",
        "Traffic Timeline": "流量时间轴",
        "Drag to zoom any range": "拖拽可缩放任意区间",
        "Daily traffic per day": "按天呈现每日流量",
        // Usage bar chart
        "Traffic Usage": "流量使用",
        "Linear": "实际比例",
        "Log": "对数比例",
        "Daily usage": "每日使用情况",
        "Monthly usage": "每月使用情况",
        "Quarterly usage": "每季度使用情况",
        "Yearly usage": "每年使用情况",
        "No recorded traffic yet.": "暂无流量记录",

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
        "Menu Bar Display": "菜单栏显示",
        "Download + Upload": "下载 + 上传",
        "Download only": "仅下载",
        "Upload only": "仅上传",
        "Icon only": "仅图标",
        "Launch at login": "开机自动启动",
        "Launch at login failed": "开机自动启动设置失败",
        "Version": "版本",

        "Traffic metric": "流量口径",
        "Totals use nettop non-loopback interface socket traffic; this is not a physical Wi-Fi/Ethernet counter.": "总量采用 nettop 非回环接口 socket 流量，不等同于物理 Wi-Fi/有线网卡计数",

        // Sampling diagnostics
        "Sampling diagnostics": "采样诊断",
        "Last nettop sample": "最近一次 nettop 采样",
        "nettop delta": "nettop 增量",
        "Waiting for nettop sample": "等待 nettop 采样",
        "nettop sampling active": "nettop 采样正常",
        "nettop sampling restarting": "nettop 采样重启中",
        "Skipped nettop rows": "已跳过的 nettop 行",

        // Network Extension / calibration status
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
