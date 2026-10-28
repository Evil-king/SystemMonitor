import AppKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - Localization

/// Two languages are enough for a menu bar utility; both dictionaries live in
/// code so the .app has no resource dependencies.
enum L10n {
    static let isChinese = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")

    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}

// MARK: - Readings

struct SwapReading {
    let total: UInt64
    let used: UInt64
    let free: UInt64
}

struct MemoryReading {
    let total: UInt64
    let used: UInt64
    let available: UInt64
    let free: UInt64
    let cached: UInt64
    let wired: UInt64
    let compressed: UInt64
    let swap: SwapReading?
}

struct DiskReading {
    let name: String
    let path: String
    let total: UInt64
    let used: UInt64
    let available: UInt64
}

struct Reading {
    let at: Date
    let memory: MemoryReading
    let disks: [DiskReading]
}

struct AppUsage {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let footprint: UInt64
}

// MARK: - Metric collection

enum Metrics {
    /// Take one reading of memory and every mounted volume.
    static func read() -> Reading {
        Reading(at: Date(), memory: readMemory(), disks: readDisks())
    }

    /// Physical memory, including the reclaimable-page accounting Activity
    /// Monitor uses, plus swap. Falls back to a conservative zero reading if
    /// the Mach calls fail.
    static func readMemory() -> MemoryReading {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(mach_host_self(), &pageSize)

        guard status == KERN_SUCCESS, pageStatus == KERN_SUCCESS else {
            return MemoryReading(
                total: total,
                used: 0,
                available: total,
                free: 0,
                cached: 0,
                wired: 0,
                compressed: 0,
                swap: readSwap()
            )
        }

        let page = UInt64(pageSize)
        let free = UInt64(stats.free_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let speculative = UInt64(stats.speculative_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page

        let available = min(total, free + inactive + speculative + purgeable)
        let used = total > available ? total - available : 0

        return MemoryReading(
            total: total,
            used: used,
            available: available,
            free: free,
            cached: inactive + speculative + purgeable,
            wired: wired,
            compressed: compressed,
            swap: readSwap()
        )
    }

    /// `vm.swapusage`, read through the kernel instead of forking sysctl.
    static func readSwap() -> SwapReading? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0, usage.xsu_total > 0 else {
            return nil
        }
        return SwapReading(total: usage.xsu_total, used: usage.xsu_used, free: usage.xsu_avail)
    }

    /// Every browsable local volume, root first. Internal APFS helper volumes
    /// (`/System/Volumes/...`) are skipped, and duplicate capacity rows are
    /// collapsed so the menu does not show the same container twice.
    static func readDisks() -> [DiskReading] {
        let keys: Set<URLResourceKey> = [.volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        var disks: [DiskReading] = []
        var seen = Set<String>()

        for url in urls {
            let path = url.path
            if path.hasPrefix("/System/Volumes/") { continue }
            let name = (try? url.resourceValues(forKeys: keys))?.volumeName ?? url.lastPathComponent
            guard let disk = statDisk(path: path, name: name) else { continue }
            let key = "\(disk.total)-\(disk.used)-\(disk.available)"
            if seen.contains(key) { continue }
            seen.insert(key)
            disks.append(disk)
        }

        // A menu with no disks is worse than a conservative root reading.
        if disks.isEmpty, let root = statDisk(path: "/", name: "Macintosh HD") {
            disks.append(root)
        }

        disks.sort { lhs, rhs in
            if lhs.path == "/" && rhs.path != "/" { return true }
            if rhs.path == "/" && lhs.path != "/" { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return disks
    }

    /// Read one mount point with statfs; nil when it is gone or unreadable.
    private static func statDisk(path: String, name: String) -> DiskReading? {
        var info = statfs()
        guard path.withCString({ statfs($0, &info) }) == 0 else { return nil }

        let block = UInt64(info.f_bsize)
        let total = UInt64(info.f_blocks) * block
        guard total > 0 else { return nil }

        let free = UInt64(info.f_bfree) * block
        let available = min(total, UInt64(info.f_bavail) * block)
        let used = total > free ? total - free : 0
        return DiskReading(name: name, path: path, total: total, used: used, available: available)
    }
}

// MARK: - Per-application memory

struct ProcessEntry {
    let parent: pid_t
    let footprint: UInt64
    let path: String?
}

/// Groups every running Dock application with its helpers and renderers and
/// sums their physical footprint, the counter Activity Monitor's Memory column
/// uses. Attribution prefers the executable's enclosing `.app` bundle (which
/// catches Chrome, Safari and Electron helpers even after they are reparented),
/// then falls back to the root's process ancestry.
enum AppUsageSampler {
    static func snapshot(excluding excluded: pid_t) -> [AppUsage] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.processIdentifier > 0
                && $0.processIdentifier != excluded
        }
        guard !apps.isEmpty else { return [] }

        struct Root {
            let key: String
            let path: String
            let app: NSRunningApplication
        }

        var roots: [Root] = []
        for app in apps {
            guard let url = app.bundleURL?.resolvingSymlinksInPath() else { continue }
            var path = url.path
            if path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty else { continue }
            roots.append(Root(key: path, path: path, app: app))
        }

        let rootPaths = roots.map(\.path)
        roots.removeAll { root in
            rootPaths.contains { other in
                other != root.path && root.path.hasPrefix(other + "/")
            }
        }

        var rootByPid: [pid_t: String] = [:]
        for root in roots { rootByPid[root.app.processIdentifier] = root.key }

        var table: [pid_t: ProcessEntry] = [:]
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        let limit = max(0, min(Int(count), pids.count))
        for index in 0..<limit {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
            guard let footprint = footprint(of: pid) else { continue }
            table[pid] = ProcessEntry(
                parent: pid_t(bsd.pbi_ppid),
                footprint: footprint,
                path: executablePath(of: pid)
            )
        }

        func ownerKey(for path: String) -> String? {
            var best: String?
            var bestLength = 0
            for root in roots {
                guard path == root.path || path.hasPrefix(root.path + "/") else { continue }
                if root.path.count > bestLength {
                    bestLength = root.path.count
                    best = root.key
                }
            }
            return best
        }

        var totals: [String: UInt64] = [:]
        for (pid, entry) in table {
            var owner: String?
            if let path = entry.path { owner = ownerKey(for: path) }
            if owner == nil {
                var parent = entry.parent
                var hops = 0
                while parent > 0 && hops < 64 {
                    if let key = rootByPid[parent] {
                        owner = key
                        break
                    }
                    parent = table[parent]?.parent ?? 0
                    hops += 1
                }
            }
            if owner == nil { owner = rootByPid[pid] }
            if let owner { totals[owner, default: 0] += entry.footprint }
        }

        var usages: [AppUsage] = []
        for root in roots {
            guard let total = totals[root.key], total > 0 else { continue }
            usages.append(AppUsage(
                pid: root.app.processIdentifier,
                name: root.app.localizedName ?? root.app.bundleIdentifier ?? "PID \(root.app.processIdentifier)",
                bundleIdentifier: root.app.bundleIdentifier,
                icon: root.app.icon,
                footprint: total
            ))
        }

        // Two copies of the same app (say WeChat and WeChat2) would otherwise
        // both read "微信"; append the bundle name only when names collide.
        var nameCounts: [String: Int] = [:]
        for usage in usages { nameCounts[usage.name, default: 0] += 1 }
        usages = usages.map { usage in
            guard nameCounts[usage.name, default: 0] > 1,
                  let app = NSRunningApplication(processIdentifier: usage.pid),
                  let url = app.bundleURL else { return usage }
            let suffix = url.deletingPathExtension().lastPathComponent
            return AppUsage(
                pid: usage.pid,
                name: "\(usage.name) (\(suffix))",
                bundleIdentifier: usage.bundleIdentifier,
                icon: usage.icon,
                footprint: usage.footprint
            )
        }

        return usages.sorted { $0.footprint > $1.footprint }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        let size = MemoryLayout<rusage_info_v4>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<rusage_info_v4>.alignment
        )
        defer { raw.deallocate() }
        let typed = raw.assumingMemoryBound(to: Optional<UnsafeMutableRawPointer>.self)
        guard proc_pid_rusage(pid, RUSAGE_INFO_V4, typed) == 0 else { return nil }
        return raw.load(as: rusage_info_v4.self).ri_phys_footprint
    }
}

// MARK: - Formatting

func percentOf(_ used: UInt64, _ total: UInt64) -> Int {
    guard total > 0 else { return 0 }
    return max(0, min(100, Int((Double(used) / Double(total) * 100).rounded())))
}

func formatBytes(_ value: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var amount = Double(value)
    var unit = 0
    while amount >= 1024 && unit < units.count - 1 {
        amount /= 1024
        unit += 1
    }
    if unit == 0 {
        return String(format: "%.0f", amount) + " " + units[unit]
    }
    if amount >= 100 {
        return String(format: "%.0f", amount) + " " + units[unit]
    }
    return String(format: "%.1f", amount) + " " + units[unit]
}

func barColor(_ percent: Int) -> NSColor {
    if percent >= 90 { return .systemRed }
    if percent >= 75 { return .systemOrange }
    return .systemGreen
}

func menuBarColor(_ percent: Int) -> NSColor {
    if percent >= 90 { return .systemRed }
    if percent >= 75 { return .systemOrange }
    return .labelColor
}

func usageDetail(used: UInt64, total: UInt64, available: UInt64) -> String {
    L10n.t(
        "已用 \(formatBytes(used)) / \(formatBytes(total)) · 可用 \(formatBytes(available))",
        "Used \(formatBytes(used)) / \(formatBytes(total)) · Available \(formatBytes(available))"
    )
}

// MARK: - Views

/// A rounded usage bar drawn with theme colors.
final class BarView: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var fillColor: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let width = max(0, min(bounds.width, bounds.width * fraction))
        guard width > 1 else { return }
        let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let fillRadius = min(radius, width / 2)
        fillColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius).fill()
    }
}

/// One menu row: name + percentage, a bar, and a used/available detail line.
final class MetricView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = BarView(frame: .zero)

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        for label in [titleLabel, valueLabel, detailLabel] {
            label.isEditable = false
            label.isSelectable = false
            label.isBordered = false
            label.drawsBackground = false
            addSubview(label)
        }
        addSubview(bar)
        layout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 16, y: 42, width: max(40, width - 150), height: 16)
        valueLabel.frame = NSRect(x: width - 124, y: 42, width: 108, height: 16)
        bar.frame = NSRect(x: 16, y: 28, width: max(0, width - 32), height: 6)
        detailLabel.frame = NSRect(x: 16, y: 7, width: max(0, width - 32), height: 14)
    }

    func update(title: String, percent: Int, detail: String, tooltip: String? = nil) {
        titleLabel.stringValue = title
        valueLabel.stringValue = "\(percent)%"
        detailLabel.stringValue = detail
        bar.fraction = CGFloat(percent) / 100
        bar.fillColor = barColor(percent)
        self.toolTip = tooltip
        needsLayout = true
    }
}

// MARK: - Launch at login

/// A user LaunchAgent, so the utility starts with the Aqua session without
/// needing an admin password or a signed copy in /Applications. The menu's
/// "Launch at login" item toggles the same file `launchctl` reads at login.
enum LaunchAtLogin {
    static let label = "local.systemmonitor"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var executablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }

    /// True only when the agent exists and points at this exact executable, so
    /// moving or reinstalling the app does not leave a stale checkmark.
    static var isEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let arguments = object["ProgramArguments"] as? [String],
              let executable = executablePath else { return false }
        return arguments.first == executable
    }

    static func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard let executable = executablePath else { return false }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "KeepAlive": false,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
                "ThrottleInterval": 10
            ]
            do {
                try FileManager.default.createDirectory(
                    at: plistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist,
                    format: .xml,
                    options: 0
                )
                try data.write(to: plistURL, options: .atomic)
            } catch {
                return false
            }
            let domain = "gui/\(getuid())"
            if isLoaded() { return true }
            return launchctl(["bootstrap", domain, plistURL.path]) == 0
        }

        // Removing the plist stops the next login, but does not boot the
        // running app out: turning the checkbox off should not quit the app.
        try? FileManager.default.removeItem(at: plistURL)
        return true
    }

    private static func isLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
    }

    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var reading: Reading?
    private var menu: NSMenu?
    private var menuOpen = false
    private var interval: TimeInterval = 5
    private var intervalItems: [NSMenuItem] = []
    private var memoryView: MetricView?
    private var diskViews: [MetricView] = []
    private var timeItem: NSMenuItem?
    private var swapItem: NSMenuItem?
    private var appUsages: [AppUsage] = []
    private var pendingRefresh: DispatchWorkItem?

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isDuplicateInstance() {
            NSApp.terminate(nil)
            return
        }

        let saved = UserDefaults.standard.double(forKey: "refreshInterval")
        interval = saved >= 2 && saved <= 120 ? saved : 5

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.50percent",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(configuration) {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            }
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = L10n.t("系统资源监视", "System monitor")
        }

        refresh()
        scheduleTimer()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        if CommandLine.arguments.contains("--preview-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }

        if let flag = CommandLine.arguments.firstIndex(of: "--capture"),
           flag + 1 < CommandLine.arguments.count {
            let directory = CommandLine.arguments[flag + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.captureDiagnostics(to: directory)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        pendingRefresh?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Menu delegate

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        if let reading { updateMenu(reading) }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        refresh()
    }

    // MARK: Refresh

    private func refresh() {
        let next = Metrics.read()
        reading = next
        appUsages = AppUsageSampler.snapshot(excluding: ProcessInfo.processInfo.processIdentifier)
        updateButton(next)
        if menu == nil || !menuOpen {
            rebuildMenu(next)
        } else {
            updateMenu(next)
        }
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        guard !menuOpen else { return }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = min(1, interval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateButton(_ reading: Reading) {
        guard let button = statusItem.button else { return }
        let memoryPercent = percentOf(reading.memory.used, reading.memory.total)
        let diskPercent = reading.disks.first.map { percentOf($0.used, $0.total) } ?? 0

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        func append(_ text: String, _ color: NSColor) {
            title.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color
            ]))
        }
        append(L10n.t("内存 ", "RAM "), .labelColor)
        append("\(memoryPercent)%", menuBarColor(memoryPercent))
        append(" · ", .tertiaryLabelColor)
        append(L10n.t("磁盘 ", "Disk "), .labelColor)
        append("\(diskPercent)%", menuBarColor(diskPercent))
        button.attributedTitle = title

        var tooltip = "\(L10n.t("内存", "Memory")) \(memoryPercent)% · \(formatBytes(reading.memory.used)) / \(formatBytes(reading.memory.total))"
        if let disk = reading.disks.first {
            tooltip += "\n\(L10n.t("磁盘", "Disk")) \(diskPercent)% · \(formatBytes(disk.used)) / \(formatBytes(disk.total))"
        }
        tooltip += "\n" + L10n.t("点击查看占用应用与明细", "Click for apps and details")
        button.toolTip = tooltip
    }

    // MARK: Menu construction

    private func rebuildMenu(_ reading: Reading) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = 340

        let header = NSMenuItem(title: L10n.t("系统资源", "System resources"), action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: L10n.t("系统资源", "System resources"), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        header.isEnabled = false
        menu.addItem(header)

        let time = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        time.isEnabled = false
        menu.addItem(time)
        timeItem = time

        menu.addItem(.separator())

        let memoryItem = NSMenuItem()
        let memoryView = MetricView(width: 340)
        memoryItem.view = memoryView
        menu.addItem(memoryItem)
        self.memoryView = memoryView

        let swap = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        swap.isEnabled = false
        menu.addItem(swap)
        swapItem = swap

        if !appUsages.isEmpty {
            menu.addItem(.separator())
            addAppSection(to: menu)
        }

        menu.addItem(.separator())

        diskViews.removeAll()
        for _ in reading.disks {
            let item = NSMenuItem()
            let view = MetricView(width: 340)
            item.view = view
            menu.addItem(item)
            diskViews.append(view)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(L10n.t("刷新", "Refresh"), #selector(refreshNow(_:)), "r"))

        let intervalItem = NSMenuItem(
            title: L10n.t("刷新间隔", "Refresh interval"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        intervalItems.removeAll()
        for value in [2.0, 5.0, 10.0, 30.0] {
            let item = NSMenuItem(
                title: L10n.t("\(Int(value)) 秒", "\(Int(value))s"),
                action: #selector(setInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: value)
            item.state = abs(interval - value) < 0.1 ? .on : .off
            submenu.addItem(item)
            intervalItems.append(item)
        }
        intervalItem.submenu = submenu
        menu.addItem(intervalItem)

        let login = actionItem(
            L10n.t("开机启动", "Launch at login"),
            #selector(toggleLaunchAtLogin(_:)),
            ""
        )
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(actionItem(
            L10n.t("打开活动监视器", "Open Activity Monitor"),
            #selector(openActivityMonitor(_:)),
            ""
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem(L10n.t("退出系统监视", "Quit System Monitor"), #selector(quit(_:)), "q"))

        statusItem.menu = menu
        self.menu = menu
        updateMenu(reading)
    }

    private func addAppSection(to menu: NSMenu) {
        let header = NSMenuItem(
            title: L10n.t("内存占用应用 · 前 10", "Memory by app · top 10"),
            action: nil,
            keyEquivalent: ""
        )
        header.attributedTitle = NSAttributedString(
            string: L10n.t("内存占用应用 · 前 10", "Memory by app · top 10"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        header.isEnabled = false
        menu.addItem(header)

        let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hint.attributedTitle = infoItem(L10n.t(
            "点击应用退出并释放内存",
            "Click an app to quit it and free memory"
        ))
        hint.isEnabled = false
        menu.addItem(hint)

        for usage in appUsages.prefix(10) {
            menu.addItem(appMenuItem(usage))
        }
        if appUsages.count > 10 {
            let more = NSMenuItem(
                title: L10n.t("其余 \(appUsages.count - 10) 个应用", "\(appUsages.count - 10) more apps"),
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for usage in appUsages.dropFirst(10) {
                submenu.addItem(appMenuItem(usage))
            }
            more.submenu = submenu
            menu.addItem(more)
        }
    }

    private func appMenuItem(_ usage: AppUsage) -> NSMenuItem {
        let displayName = usage.name
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let size = formatBytes(usage.footprint)

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 268, options: [:])]
        paragraph.lineBreakMode = .byTruncatingTail
        let title = NSMutableAttributedString(
            string: "\(displayName)\t\(size)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        title.addAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            range: NSRange(location: displayName.utf16.count + 1, length: size.utf16.count)
        )

        let item = NSMenuItem(
            title: displayName,
            action: #selector(releaseApp(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = NSNumber(value: usage.pid)
        item.attributedTitle = title
        item.image = usage.icon
        item.toolTip = L10n.t(
            "\(displayName) 占用 \(size)；点击退出应用并释放内存",
            "\(displayName) uses \(size); click to quit it and free memory"
        )
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func infoItem(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    private func updateMenu(_ reading: Reading) {
        if let timeItem {
            timeItem.attributedTitle = infoItem(L10n.t(
                "更新于 \(timeFormatter.string(from: reading.at))",
                "Updated \(timeFormatter.string(from: reading.at))"
            ))
        }

        let memory = reading.memory
        let memoryPercent = percentOf(memory.used, memory.total)
        memoryView?.update(
            title: L10n.t("内存", "Memory"),
            percent: memoryPercent,
            detail: usageDetail(used: memory.used, total: memory.total, available: memory.available),
            tooltip: L10n.t("缓存 \(formatBytes(memory.cached)) · 联动内存 \(formatBytes(memory.wired))",
                            "Cached \(formatBytes(memory.cached)) · Wired \(formatBytes(memory.wired))")
        )

        if let swapItem {
            if let swap = memory.swap, swap.total > 0 {
                swapItem.isHidden = false
                swapItem.attributedTitle = infoItem(L10n.t(
                    "交换空间 \(formatBytes(swap.used)) / \(formatBytes(swap.total))",
                    "Swap \(formatBytes(swap.used)) / \(formatBytes(swap.total))"
                ))
            } else {
                swapItem.isHidden = true
            }
        }

        if diskViews.count != reading.disks.count {
            if !menuOpen { rebuildMenu(reading) }
            return
        }

        for (index, disk) in reading.disks.enumerated() {
            let percent = percentOf(disk.used, disk.total)
            let title = index == 0 ? L10n.t("磁盘", "Disk") : disk.name
            diskViews[index].update(
                title: title,
                percent: percent,
                detail: usageDetail(used: disk.used, total: disk.total, available: disk.available),
                tooltip: disk.path
            )
        }
    }

    // MARK: Actions

    @objc private func releaseApp(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let pid = pid_t(number.int32Value)
        guard pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              let usage = appUsages.first(where: { $0.pid == pid }),
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("释放内存：\(usage.name)", "Free memory: \(usage.name)")
        var detail = L10n.t(
            "退出该应用预计释放 \(formatBytes(usage.footprint))。未保存的修改会丢失。",
            "Quitting it should free about \(formatBytes(usage.footprint)). Unsaved changes will be lost."
        )
        if let bundle = usage.bundleIdentifier, bundle.localizedCaseInsensitiveContains("deepseek") {
            detail += "\n" + L10n.t(
                "注意：这会关闭当前 DSH 会话。",
                "Note: this closes the current DSH session."
            )
        }
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.t("取消", "Cancel"))
        alert.addButton(withTitle: L10n.t("退出应用", "Quit app"))
        alert.addButton(withTitle: L10n.t("强制退出", "Force quit"))

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if !app.terminate() { NSSound.beep() }
        } else if response == .alertThirdButtonReturn {
            if !app.forceTerminate() { NSSound.beep() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func refreshNow(_ sender: Any?) {
        refresh()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        interval = number.doubleValue
        UserDefaults.standard.set(interval, forKey: "refreshInterval")
        for item in intervalItems {
            guard let value = item.representedObject as? NSNumber else { continue }
            item.state = abs(value.doubleValue - interval) < 0.1 ? .on : .off
        }
        scheduleTimer()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let wanted = !LaunchAtLogin.isEnabled
        if LaunchAtLogin.setEnabled(wanted) {
            sender.state = wanted ? .on : .off
            return
        }
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("无法修改开机启动", "Could not change the login item")
        alert.informativeText = L10n.t(
            "请确认应用位于 ~/Applications 或 /Applications，并检查 ~/Library/LaunchAgents 的写入权限。",
            "Make sure the app is in ~/Applications or /Applications and that ~/Library/LaunchAgents is writable."
        )
        alert.runModal()
    }

    @objc private func openActivityMonitor(_ sender: Any?) {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func isDuplicateInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != current }
    }

    // MARK: Diagnostics

    /// Development helper behind `--capture <dir>`: saves the status button,
    /// every on-screen window owned by this process, and a JSON report. Used to
    /// verify rendering in environments without Screen Recording permission.
    private func captureDiagnostics(to directory: String) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var report: [String: Any] = [:]

        if let button = statusItem.button {
            button.layoutSubtreeIfNeeded()
            if let window = button.window {
                let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
                report["statusButtonFrame"] = [
                    "x": frame.origin.x,
                    "y": frame.origin.y,
                    "width": frame.width,
                    "height": frame.height
                ]
            }
            report["statusTitle"] = button.attributedTitle.string
            report["statusHasImage"] = button.image != nil
            if let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: directory + "/status-button.png"))
                }
            }
        }

        if let reading {
            report["memoryPercent"] = percentOf(reading.memory.used, reading.memory.total)
            report["disks"] = reading.disks.map { disk in
                ["name": disk.name, "path": disk.path, "percent": percentOf(disk.used, disk.total)]
            }
        }
        report["menuItems"] = menu?.items.count ?? 0
        report["menuOpen"] = menuOpen
        report["menuTitles"] = menu?.items.map { item -> String in
            if let attributed = item.attributedTitle, attributed.length > 0 {
                return attributed.string
            }
            return item.title
        } ?? []
        report["appRows"] = appUsages.prefix(5).map { usage in
            ["name": usage.name, "pid": Int(usage.pid), "footprint": usage.footprint]
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let infos = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]) ?? []
        var windows: [[String: Any]] = []
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == pid else { continue }
            let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let name = info[kCGWindowName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? NSNumber ?? 0
            let bounds = info[kCGWindowBounds as String] ?? [:]
            windows.append(["number": number, "name": name, "layer": layer, "bounds": bounds])
        }
        report["windows"] = windows

        // NSMenu is not an NSView, so the rows are rendered individually. This
        // captures the exact MetricView instances the open menu is using.
        let rows: [(String, MetricView?)] = [("memory", memoryView)]
            + diskViews.enumerated().map { ("disk-\($0.offset)", Optional($0.element)) }
        for (name, view) in rows {
            guard let view else { continue }
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: directory + "/row-\(name).png"))
                }
            }
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: directory + "/report.json"))
        }
    }
}

// MARK: - Scriptable one-shot output

extension Reading {
    func jsonObject(apps: [AppUsage]) -> [String: Any] {
        var memory: [String: Any] = [
            "total": self.memory.total,
            "used": self.memory.used,
            "available": self.memory.available,
            "free": self.memory.free,
            "cached": self.memory.cached,
            "wired": self.memory.wired,
            "compressed": self.memory.compressed
        ]
        if let swap = self.memory.swap {
            memory["swap"] = ["total": swap.total, "used": swap.used, "free": swap.free]
        }
        let disks: [[String: Any]] = self.disks.map { disk in
            [
                "name": disk.name,
                "path": disk.path,
                "total": disk.total,
                "used": disk.used,
                "available": disk.available,
                "percent": percentOf(disk.used, disk.total)
            ]
        }
        let appRows: [[String: Any]] = apps.map { usage in
            [
                "name": usage.name,
                "pid": Int(usage.pid),
                "bundle": usage.bundleIdentifier ?? "",
                "footprint": usage.footprint
            ]
        }
        return [
            "at": ISO8601DateFormatter().string(from: self.at),
            "memory": memory,
            "disks": disks,
            "apps": appRows
        ]
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--enable-login") {
    let enabled = LaunchAtLogin.setEnabled(true)
    print(enabled ? "enabled" : "failed")
    exit(enabled ? 0 : 1)
}

if CommandLine.arguments.contains("--disable-login") {
    let disabled = LaunchAtLogin.setEnabled(false)
    print(disabled ? "disabled" : "failed")
    exit(disabled ? 0 : 1)
}

if CommandLine.arguments.contains("--once") {
    let reading = Metrics.read()
    let apps = AppUsageSampler.snapshot(excluding: getpid())
    let data = try JSONSerialization.data(
        withJSONObject: reading.jsonObject(apps: apps),
        options: [.prettyPrinted, .sortedKeys]
    )
    print(String(data: data, encoding: .utf8) ?? "{}")
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
