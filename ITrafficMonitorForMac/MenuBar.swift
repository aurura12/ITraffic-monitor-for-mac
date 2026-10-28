//
//  MenuBar.swift
//  ITrafficMonitorForMac
//

import AppKit
import Combine
import SwiftUI

struct MenuBarRateText: Equatable {
    let download: String
    let upload: String

    var rows: [String] {
        [upload, download]
    }

    init(downloadRate: Int, uploadRate: Int) {
        download = "↓ " + formatMenuBarRate(bytes: downloadRate)
        upload = "↑ " + formatMenuBarRate(bytes: uploadRate)
    }
}

enum MenuBarLayout {
    /// 状态项宽度自适应两行文本内容，左右各留 2pt 的点击余量。
    static let statusItemHorizontalPadding: CGFloat = 4
    static let statusItemHeight: CGFloat = 22
}

enum MenuBarStatusItemConfiguration {
    /// Keep the AppKit status-item identity stable across relaunches.
    static let autosaveName = "com.foamzou.ITrafficMonitorV2.menuBar"
}

enum MenuBarPopoverConfiguration {
    /// Do not leave a transient status-item popover stranded on screen if the
    /// user clicks elsewhere without explicitly closing it.
    static let autoDismissInterval: TimeInterval = 5
}

enum MenuBarPopoverLayout {
    static let width: CGFloat = 320
    /// Floor for the measured content height. The hosting view reports a zero
    /// fitting size before its first layout, and a zero-height popover is
    /// invisible with no way to open it again.
    static let minimumHeight: CGFloat = 160
}

/// Height for the popover's fixed width: the content's fitting height, rounded
/// up, and never below the floor. Exposed at file scope so the sizing rule is
/// testable without a window.
func menuBarPopoverHeight(fittingHeight: CGFloat) -> CGFloat {
    max(MenuBarPopoverLayout.minimumHeight, ceil(fittingHeight))
}

/// What the menu-bar status item renders. Persisted in UserDefaults and
/// switched from Settings; MenuBarController re-applies it on change.
enum MenuBarDisplayMode: String, CaseIterable {
    case both
    case downloadOnly
    case uploadOnly
    case iconOnly

    static let defaultsKey = "menuBarDisplayMode"

    static var current: MenuBarDisplayMode {
        MenuBarDisplayMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .both
    }
}

extension Notification.Name {
    /// Posted when the user changes the menu-bar display mode in Settings so
    /// the AppKit status item can re-render without an app restart.
    static let menuBarDisplayModeDidChange = Notification.Name("menuBarDisplayModeDidChange")
}

/// Compact rate format for the narrow, two-line status item.
func formatMenuBarRate(bytes: Int) -> String {
    let kilobytes = Double(max(0, bytes)) / 1024
    if kilobytes < 1024 {
        if kilobytes < 10 {
            return String(format: "%.1fK/s", kilobytes)
        }
        return String(format: "%.0fK/s", kilobytes)
    }

    let megabytes = kilobytes / 1024
    if megabytes < 1024 {
        return String(format: "%.1fM/s", megabytes)
    }

    return String(format: "%.1fG/s", megabytes / 1024)
}

enum MenuBarRatePresentation: Equatable {
    case text([String])
    case icon(String)
}

class MenuBarRateView: NSView {
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private var icon: NSImage?
    private(set) var presentation: MenuBarRatePresentation = .text([])

    /// What the item currently renders (two-line rates, a single direction, or
    /// an icon-only marker). Mirrors the persisted menu-bar display mode.
    private var mode: MenuBarDisplayMode = .both
    /// While monitoring is paused no frames arrive, so the live-rate updates are
    /// suppressed and the item shows a static paused marker instead of stale 0s.
    private var isPaused = false
    /// Last rates, cached so a mode switch can re-render immediately instead of
    /// waiting for the next nettop frame.
    private var downloadRateValue = 0
    private var uploadRateValue = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        mode = MenuBarDisplayMode.current
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(downloadRate: Int, uploadRate: Int) {
        downloadRateValue = downloadRate
        uploadRateValue = uploadRate
        render()
    }

    /// Swap the live rates for a paused marker and back.
    func setPaused(_ paused: Bool) {
        isPaused = paused
        render()
    }

    /// Switch the rendering mode (two-line / single direction / icon only).
    func apply(mode: MenuBarDisplayMode) {
        self.mode = mode
        render()
    }

    private func render() {
        let next: MenuBarRatePresentation
        if mode == .iconOnly {
            next = .icon(isPaused ? "pause.circle" : "arrow.up.arrow.down")
        } else if isPaused {
            next = .text(mode == .both ? ["⏸", L("Paused")] : [pausedText])
        } else {
            let text = MenuBarRateText(downloadRate: downloadRateValue, uploadRate: uploadRateValue)
            switch mode {
            case .both: next = .text(text.rows)
            case .downloadOnly: next = .text([text.download])
            case .uploadOnly: next = .text([text.upload])
            case .iconOnly: return
            }
        }

        // macOS snapshots status-item subviews for Control Center. A stack of
        // text fields and an image view makes that path repeatedly lay out and
        // render descendant layers. Draw the small presentation in one view,
        // and only invalidate it when the displayed (rounded) value changes.
        guard next != presentation else { return }
        let oldWidth = neededWidth
        presentation = next
        if case .icon(let symbol) = next {
            icon = image(for: symbol)
            setAccessibilityValue(isPaused ? L("Paused") : AppDelegate.appDisplayName)
        } else {
            icon = nil
            if case .text(let rows) = next {
                setAccessibilityValue(rows.joined(separator: ", "))
            }
        }
        if neededWidth != oldWidth {
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
    }

    private var pausedText: String { "⏸ " + L("Paused") }

    private func image(for symbol: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [.labelColor]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: AppDelegate.appDisplayName)?
            .withSymbolConfiguration(configuration)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if case .icon(let symbol) = presentation {
            icon = image(for: symbol)
        }
        needsDisplay = true
    }

    /// Width of the widest currently visible row, so the status item only claims
    /// the menu-bar space its current mode actually needs.
    var neededWidth: CGFloat {
        switch presentation {
        case .text(let rows):
            return rows.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        case .icon:
            return icon?.size.width ?? 13
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: neededWidth, height: MenuBarLayout.statusItemHeight)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        switch presentation {
        case .text(let rows):
            guard !rows.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let rowHeight = bounds.height / CGFloat(rows.count)
            for (index, row) in rows.enumerated() {
                let text = row as NSString
                let height = text.size(withAttributes: attributes).height
                text.draw(at: NSPoint(
                    x: MenuBarLayout.statusItemHorizontalPadding / 2,
                    y: CGFloat(index) * rowHeight + (rowHeight - height) / 2
                ), withAttributes: attributes)
            }
        case .icon:
            guard let icon else { return }
            let size = icon.size
            icon.draw(in: NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            ), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // This view only renders the live rates. Let the enclosing
        // NSStatusBarButton receive the click so its target/action remains
        // reliable when the popover is already visible.
        nil
    }
}

/// Today's traffic totals shown in the popover. Filled asynchronously from
/// the persisted per-frame samples, so the numbers survive app restarts and
/// stay consistent with the dashboard's daily bars.
final class TodayUsageModel: ObservableObject {
    @Published private(set) var inBytes = 0
    @Published private(set) var outBytes = 0

    func update(total: TrafficTotal) {
        inBytes = max(0, total.inBytes)
        outBytes = max(0, total.outBytes)
    }

    var totalBytes: Int {
        inBytes + outBytes
    }
}

struct MenuBarSummaryView: View {
    @EnvironmentObject private var i18n: LocalizationManager
    @ObservedObject var todayUsage: TodayUsageModel

    let onOpenDashboard: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AppDelegate.appDisplayName, systemImage: "network")
                    .font(.headline)
                Spacer()
                Text(i18n.text("Today's Usage"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            usageRow(
                title: i18n.text("Download"),
                bytes: todayUsage.inBytes,
                color: Theme.download,
                symbol: "arrow.down"
            )
            usageRow(
                title: i18n.text("Upload"),
                bytes: todayUsage.outBytes,
                color: Theme.upload,
                symbol: "arrow.up"
            )

            Divider()

            HStack(spacing: 8) {
                Text(i18n.text("Total"))
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatBytesTotal(bytes: todayUsage.totalBytes))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
            }

            HStack(spacing: 8) {
                Button(i18n.text("Open Dashboard"), action: onOpenDashboard)
                    .keyboardShortcut(.defaultAction)
                Button(i18n.text("Settings"), action: onOpenSettings)
                Button(i18n.text("Quit"), action: onQuit)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func usageRow(title: String, bytes: Int, color: Color, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .frame(width: 16)
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(formatBytesTotal(bytes: bytes))
                .font(.system(.body, design: .monospaced))
        }
    }
}

final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let rateView: MenuBarRateView
    private let todayUsage = TodayUsageModel()
    private var refreshTimer: Timer?
    private var popoverDismissTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Set by AppDelegate once sampling is wired up. Wrapped weakly: the
    /// delegate owns the Network instance.
    weak var network: Network?
    /// Whether the user paused sampling from the status-item context menu.
    private(set) var isMonitoringPaused = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        // frame 仅作初始占位，随后会被 button 的四边约束接管，
        // 实际水平宽度由 resizeToFitContent() 按文本内容自适应设置。
        rateView = MenuBarRateView(frame: NSRect(
            x: 0,
            y: 0,
            width: MenuBarLayout.statusItemHeight,
            height: MenuBarLayout.statusItemHeight
        ))
        super.init()

        statusItem.autosaveName = MenuBarStatusItemConfiguration.autosaveName
        configureStatusItem()
        configurePopover()
    }

    deinit {
        refreshTimer?.invalidate()
        popoverDismissTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = ""
        button.isBordered = false
        button.toolTip = AppDelegate.appDisplayName
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        // Distinguish the two mouse buttons: left opens the popover, right (or
        // control-click) opens the context menu.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        rateView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(rateView)
        NSLayoutConstraint.activate([
            rateView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            rateView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            rateView.topAnchor.constraint(equalTo: button.topAnchor),
            rateView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        resizeToFitContent()

        SharedStore.statusDataModel.$rates
            .receive(on: RunLoop.main)
            .sink { [weak self] rates in
                self?.rateView.update(downloadRate: rates.inBytes, uploadRate: rates.outBytes)
                self?.resizeToFitContent()
            }
            .store(in: &cancellables)

        // The display mode is a Settings toggle; re-render and re-fit the item
        // in place when it changes instead of requiring a relaunch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarDisplayModeDidChange),
            name: .menuBarDisplayModeDidChange,
            object: nil
        )
    }

    @objc private func menuBarDisplayModeDidChange() {
        rateView.apply(mode: MenuBarDisplayMode.current)
        resizeToFitContent()
    }

    /// 状态项宽度跟随两行文本中较宽一行自适应，避免固定宽度在菜单栏留白。
    private func resizeToFitContent() {
        let width = ceil(rateView.neededWidth) + MenuBarLayout.statusItemHorizontalPadding
        if width != statusItem.length {
            statusItem.length = width
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        // The popover is already built at launch; avoid adding an opening
        // animation to every status-item click.
        popover.animates = false
        let contentViewController = NSHostingController(
            rootView: MenuBarSummaryView(
                todayUsage: todayUsage,
                onOpenDashboard: { [weak self] in self?.openDashboard() },
                onOpenSettings: { [weak self] in self?.openSettings() },
                onQuit: { [weak self] in self?.quit() }
            )
            .withGlobalEnvironmentObjects()
        )
        popover.contentViewController = contentViewController

        // Keep the popover frame in sync with the SwiftUI view. A stale
        // hard-coded height leaves the hosting view bottom-aligned and clips
        // the header when the popover is shown again after another window was
        // opened.
        popover.contentSize = NSSize(
            width: MenuBarPopoverLayout.width,
            height: menuBarPopoverHeight(fittingHeight: contentViewController.view.fittingSize.height)
        )
    }

    /// Re-measure before every show. The content height depends on the active
    /// language and on the paused marker, so a size captured at launch clips the
    /// buttons after a language switch. Measuring at show time is also what
    /// keeps the hosting view from staying bottom-aligned in a stale frame.
    private func resizePopoverToFitContent() {
        guard let contentViewController = popover.contentViewController else { return }
        let height = menuBarPopoverHeight(
            fittingHeight: contentViewController.view.fittingSize.height
        )
        guard popover.contentSize.height != height else { return }
        popover.contentSize = NSSize(width: MenuBarPopoverLayout.width, height: height)
    }

    private func schedulePopoverAutoDismiss() {
        popoverDismissTimer?.invalidate()

        let timer = Timer(
            timeInterval: MenuBarPopoverConfiguration.autoDismissInterval,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.popoverDismissTimer = nil
            guard self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        popoverDismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPopoverAutoDismiss() {
        popoverDismissTimer?.invalidate()
        popoverDismissTimer = nil
    }

    /// Query the current local day's total from the history database.
    private func refreshTodayUsage() {
        let day = dayIndex(for: Date(), calendar: .current)
        SharedStore.recorder.dayTotalTraffic(day: day) { [weak self] total in
            self?.todayUsage.update(total: total)
        }
    }

    /// While the popover stays open the day totals keep climbing; refresh
    /// every few seconds so the numbers stay live without polling the DB
    /// when the popover is hidden.
    private func scheduleTodayUsageRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.refreshTodayUsage()
        }
        refreshTimer?.tolerance = 0.3
    }

    func popoverWillShow(_ notification: Notification) {
        resizePopoverToFitContent()
        refreshTodayUsage()
        scheduleTodayUsageRefresh()
    }

    func popoverDidClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancelPopoverAutoDismiss()
    }

    /// Route a status-item click by mouse button: secondary (right click or
    /// control-click) shows the context menu, primary toggles the popover.
    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    /// Pop the status item's menu at the button. Assigning `statusItem.menu`
    /// makes the next click display the menu instead of sending the action, so
    /// we attach it, simulate the click, then detach it to keep the primary
    /// click wired to the popover.
    private func showContextMenu() {
        cancelPopoverAutoDismiss()
        if popover.isShown { popover.performClose(nil) }

        let menu = makeContextMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        addItem(to: menu, title: L("Open Dashboard"), action: #selector(menuOpenDashboard))
        addItem(to: menu, title: L("Settings"), action: #selector(menuOpenSettings))
        menu.addItem(.separator())
        addItem(
            to: menu,
            title: isMonitoringPaused ? L("Resume Monitoring") : L("Pause Monitoring"),
            action: #selector(menuToggleMonitoring)
        )
        menu.addItem(.separator())
        addItem(to: menu, title: L("Quit"), action: #selector(menuQuit))
        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuOpenDashboard() { openDashboard() }

    @objc private func menuOpenSettings() { openSettings() }

    @objc private func menuQuit() { quit() }

    /// Stop or resume nettop sampling. Pausing halts both the live rates and
    /// history recording; the ledger simply gains no samples while paused.
    @objc private func menuToggleMonitoring() {
        isMonitoringPaused.toggle()
        if isMonitoringPaused {
            network?.stopListenNetwork()
            // Drop the now-frozen live values so the UI does not show the last
            // frame's rates as if they were current.
            SharedStore.statusDataModel.update(totalInBytes: 0, totalOutBytes: 0)
        } else {
            network?.startListenNetwork()
        }
        rateView.setPaused(isMonitoringPaused)
        resizeToFitContent()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            cancelPopoverAutoDismiss()
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            schedulePopoverAutoDismiss()
        }
    }

    private func openDashboard() {
        cancelPopoverAutoDismiss()
        popover.performClose(nil)
        AppDelegate.showDashboard()
    }

    private func openSettings() {
        cancelPopoverAutoDismiss()
        popover.performClose(nil)
        AppDelegate.showSettings()
    }

    private func quit() {
        cancelPopoverAutoDismiss()
        popover.performClose(nil)
        NSApp.terminate(nil)
    }
}
