import AppKit
import Foundation
import SwiftUI
import UserNotifications

// =============================================================================
// DevMon Menu Bar App - Rich SwiftUI Popover Edition
// Lightweight macOS status bar app for DevMon process monitor
// Compile: swiftc -O -o devmon-menubar DevMonMenuBar.swift -framework AppKit
// =============================================================================

// MARK: - Data Types

struct DevProcess: Identifiable {
    let id: Int
    let pid: Int
    let name: String
    let command: String
    let isOrphan: Bool
    let orphanAgeSec: Int?
    let memoryMB: Int
    let port: Int?
    let connections: Int

    var statusEmoji: String {
        if !isOrphan {
            return "\u{1F7E2}" // green
        }
        if let age = orphanAgeSec, age > 1200 {
            return "\u{1F534}" // red - old orphan
        }
        return "\u{1F7E1}" // yellow - recent orphan
    }

    var orphanAgeFormatted: String? {
        guard let age = orphanAgeSec else { return nil }
        if age < 60 { return "\(age)s" }
        if age < 3600 { return "\(age / 60)m" }
        return "\(age / 3600)h\((age % 3600) / 60)m"
    }
}

struct DevPort: Identifiable {
    let id: Int
    let port: Int
    let pid: Int
    let processName: String
    let connections: Int
}

struct SystemProcess: Identifiable {
    let id: String  // app name
    let name: String
    let totalMB: Int
    let processCount: Int
    let pids: [Int]
}

let protectedProcesses: Set<String> = ["WindowServer", "loginwindow", "kernel_task", "Finder", "Dock", "SystemUIServer", "launchd"]

// MARK: - Shell Helpers

func runShellCommand(_ command: String) -> String {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    // Use login shell to get full PATH (critical when launched as .app)
    process.arguments = ["-lc", command]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.environment = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory()
    ]

    do {
        try process.run()
    } catch {
        debugLog("Shell error: \(error)")
        return ""
    }

    // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func debugLog(_ message: String) {
    let logDir = NSString(string: "~/Library/Logs/devmon").expandingTildeInPath
    let logFile = (logDir as NSString).appendingPathComponent("menubar-debug.log")
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: logFile))
        }
    }
}

func runInTerminal(_ command: String) {
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "tell application \"Terminal\" to do script \"\(escaped)\""
    if let appleScript = NSAppleScript(source: script) {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}

// MARK: - Status Collection

func getMemoryPressure() -> Int {
    let pageSizeStr = runShellCommand("sysctl -n hw.pagesize")
    let pageSize = Int(pageSizeStr) ?? 4096

    let vmOutput = runShellCommand("vm_stat")
    if vmOutput.isEmpty { return 0 }

    func extractPages(_ label: String) -> Int {
        for line in vmOutput.components(separatedBy: "\n") {
            if line.contains(label) {
                let parts = line.components(separatedBy: " ").filter { !$0.isEmpty }
                if let last = parts.last {
                    let cleaned = last.replacingOccurrences(of: ".", with: "")
                    return Int(cleaned) ?? 0
                }
            }
        }
        return 0
    }

    let active = extractPages("Pages active")
    let wired = extractPages("Pages wired")
    let compressed = extractPages("Pages occupied by compressor")

    let totalBytesStr = runShellCommand("sysctl -n hw.memsize")
    let totalBytes = Int(totalBytesStr) ?? 1

    let usedBytes = (active + wired + compressed) * pageSize
    let pressure = usedBytes * 100 / totalBytes

    return pressure
}

func getSwapUsageMB() -> Int {
    let output = runShellCommand("sysctl vm.swapusage 2>/dev/null")
    // Format: "vm.swapusage: total = 6144.00M  used = 5222.50M  free = 921.50M  (encrypted)"
    // or with G suffix on some systems
    guard !output.isEmpty else { return 0 }
    // Extract "used = XXXM" or "used = XXXG"
    let parts = output.components(separatedBy: "used = ")
    guard parts.count > 1 else { return 0 }
    let usedPart = parts[1].components(separatedBy: " ").first ?? ""
    let cleaned = usedPart.replacingOccurrences(of: "M", with: "")
                          .replacingOccurrences(of: "G", with: "")
    let value = Double(cleaned) ?? 0
    if usedPart.hasSuffix("G") {
        return Int(value * 1024)
    }
    return Int(value)
}

func checkIsPaused() -> Bool {
    let pausedPath = NSString(string: "~/.config/devmon/state/paused").expandingTildeInPath
    return FileManager.default.fileExists(atPath: pausedPath)
}

func devmonPath() -> String? {
    let candidates = [
        NSString(string: "~/.local/bin/devmon").expandingTildeInPath,
        "/usr/local/bin/devmon"
    ]
    for path in candidates {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return nil
}

// MARK: - Rich Data Collection

let devProcessPattern = "node|next-server|vite|webpack|esbuild|postcss|turbopack|ts-node|tsx"

func loadOrphanTimestamps() -> [Int: Int] {
    let path = NSString(string: "~/.config/devmon/state/orphans.txt").expandingTildeInPath
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var result: [Int: Int] = [:]
    for line in content.components(separatedBy: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
        if parts.count >= 2, let pid = Int(parts[0]), let ts = Int(parts[1]) {
            result[pid] = ts
        }
    }
    return result
}

func getListeningPort(forPid pid: Int) -> Int? {
    let output = runShellCommand("lsof -nP -p \(pid) -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | sed 's/.*://' | head -1")
    return Int(output)
}

func getConnectionCount(forPort port: Int) -> Int {
    let output = runShellCommand("lsof -nP -iTCP:\(port) -sTCP:ESTABLISHED 2>/dev/null | tail -n +2 | wc -l")
    return Int(output.trimmingCharacters(in: .whitespaces)) ?? 0
}

func getTopMemoryMap() -> [Int: Int] {
    // Use top to get accurate physical memory (matches Activity Monitor)
    let output = runShellCommand("top -l 1 -stats pid,mem 2>/dev/null")
    var memMap: [Int: Int] = [:]
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
        let memStr = parts[1]
        var memMB = 0
        if memStr.hasSuffix("G") || memStr.hasSuffix("G+") {
            let cleaned = memStr.replacingOccurrences(of: "G+", with: "").replacingOccurrences(of: "G", with: "")
            memMB = Int((Double(cleaned) ?? 0) * 1024)
        } else if memStr.hasSuffix("M") || memStr.hasSuffix("M+") {
            let cleaned = memStr.replacingOccurrences(of: "M+", with: "").replacingOccurrences(of: "M", with: "")
            memMB = Int(Double(cleaned) ?? 0)
        } else if memStr.hasSuffix("K") || memStr.hasSuffix("K+") {
            let cleaned = memStr.replacingOccurrences(of: "K+", with: "").replacingOccurrences(of: "K", with: "")
            memMB = max(1, Int((Double(cleaned) ?? 0) / 1024))
        }
        if memMB > 0 { memMap[pid] = memMB }
    }
    return memMap
}

func collectDevProcesses() -> [DevProcess] {
    let psOutput = runShellCommand("ps -eo pid,ppid,tty,comm,args 2>/dev/null")
    guard !psOutput.isEmpty else { return [] }

    let orphanTimestamps = loadOrphanTimestamps()
    let now = Int(Date().timeIntervalSince1970)
    let memMap = getTopMemoryMap()
    var processes: [DevProcess] = []

    let patternComponents = devProcessPattern.components(separatedBy: "|")

    for line in psOutput.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("PID") { continue }

        // Parse ps columns: pid ppid tty comm args...
        let cols = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
        guard cols.count >= 4 else { continue }

        guard let pid = Int(cols[0]) else { continue }
        let ppid = Int(cols[1]) ?? 0
        let tty = cols[2]
        let comm = (cols[3] as NSString).lastPathComponent

        // Match against dev process pattern
        let matchesPattern = patternComponents.contains { pattern in
            comm.localizedCaseInsensitiveContains(pattern)
        }
        guard matchesPattern else { continue }

        // Full command args (everything from col 4 onward)
        let argsStart = cols.count > 4 ? cols[4...].joined(separator: " ") : comm
        let truncatedArgs = argsStart.count > 80 ? String(argsStart.prefix(80)) + "..." : argsStart

        let isOrphan = (tty == "??" && ppid == 1)

        var orphanAge: Int? = nil
        if isOrphan {
            if let firstSeen = orphanTimestamps[pid] {
                orphanAge = now - firstSeen
            } else {
                orphanAge = 0
            }
        }

        let memMB = memMap[pid] ?? 0
        let port = getListeningPort(forPid: pid)
        let connections = port != nil ? getConnectionCount(forPort: port!) : 0

        processes.append(DevProcess(
            id: pid,
            pid: pid,
            name: comm,
            command: truncatedArgs,
            isOrphan: isOrphan,
            orphanAgeSec: orphanAge,
            memoryMB: memMB,
            port: port,
            connections: connections
        ))
    }

    return processes.sorted { $0.memoryMB > $1.memoryMB }
}

func collectPorts() -> [DevPort] {
    let output = runShellCommand("lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | awk 'NR>1{print $2, $1, $9}'")
    guard !output.isEmpty else { return [] }

    var seen = Set<Int>()
    var ports: [DevPort] = []

    for line in output.components(separatedBy: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 3 else { continue }
        guard let pid = Int(parts[0]) else { continue }
        let name = parts[1]
        let addrPort = parts[2]
        let portStr = addrPort.components(separatedBy: ":").last ?? ""
        guard let port = Int(portStr) else { continue }

        // Filter to 3000-9000 range
        guard port >= 3000 && port <= 9000 else { continue }

        // Deduplicate (IPv4/IPv6 dups)
        guard !seen.contains(port) else { continue }
        seen.insert(port)

        let connections = getConnectionCount(forPort: port)
        ports.append(DevPort(id: port, port: port, pid: pid, processName: name, connections: connections))
    }

    return ports.sorted { $0.port < $1.port }
}

func collectTopMemory() -> [SystemProcess] {
    // Use top to get physical memory (matches Activity Monitor)
    let output = runShellCommand("top -l 1 -o mem -n 100 -stats pid,mem,command 2>/dev/null")

    // Aggregate by command name
    var totals: [String: Int] = [:]
    var counts: [String: Int] = [:]
    var pidMap: [String: [Int]] = [:]

    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let cols = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
        guard cols.count >= 3, let pid = Int(cols[0]) else { continue }

        var memStr = cols[1]
        memStr = memStr.replacingOccurrences(of: "+", with: "")
        var mb = 0
        if memStr.hasSuffix("G") {
            let cleaned = memStr.replacingOccurrences(of: "G", with: "")
            mb = Int((Double(cleaned) ?? 0) * 1024)
        } else if memStr.hasSuffix("M") {
            let cleaned = memStr.replacingOccurrences(of: "M", with: "")
            mb = Int(Double(cleaned) ?? 0)
        } else if memStr.hasSuffix("K") {
            let cleaned = memStr.replacingOccurrences(of: "K", with: "")
            mb = max(1, Int((Double(cleaned) ?? 0) / 1024))
        }
        guard mb > 0 else { continue }

        let cmd = cols[2]
        totals[cmd, default: 0] += mb
        counts[cmd, default: 0] += 1
        pidMap[cmd, default: []].append(pid)
    }

    // Map friendly names for known apps
    let friendlyNames: [String: String] = [
        "2.1.42": "Claude",
        "Google": "Google Chrome",
        "pycharm": "PyCharm",
        "node": "Node.js",
        "WindowServer": "WindowServer",
        "Terminal": "Terminal",
        "WhatsApp": "WhatsApp",
        "Spotify": "Spotify",
        "cef_server": "PyCharm Helper",
        "Finder": "Finder",
        "Safari": "Safari",
        "Code": "VS Code",
        "Cursor": "Cursor",
        "Slack": "Slack",
        "Mail": "Mail",
    ]

    var results: [SystemProcess] = []
    for (cmd, totalMB) in totals {
        guard totalMB >= 30 else { continue }  // skip tiny processes
        let displayName = friendlyNames[cmd] ?? cmd
        results.append(SystemProcess(
            id: cmd,
            name: displayName,
            totalMB: totalMB,
            processCount: counts[cmd] ?? 1,
            pids: pidMap[cmd] ?? []
        ))
    }

    return results.sorted { $0.totalMB > $1.totalMB }
}

// MARK: - View Model

class DevMonViewModel: ObservableObject {
    let physicalMemoryGB: Double

    init() {
        let memStr = runShellCommand("sysctl -n hw.memsize")
        let memBytes = Double(memStr) ?? 0
        self.physicalMemoryGB = memBytes / 1_073_741_824.0
    }

    @Published var memoryPressure: Int = 0
    @Published var swapUsageMB: Int = 0
    @Published var processes: [DevProcess] = []
    @Published var ports: [DevPort] = []
    @Published var systemProcesses: [SystemProcess] = []
    @Published var isPaused: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var killingPIDs: Set<Int> = []
    @Published var lastRefresh: Date = Date()
    @Published var previousPressure: Int = 0
    var hasNotifiedCritical: Bool = false

    var memoryTrend: String {
        if memoryPressure > previousPressure + 2 { return " \u{2191}" }
        if memoryPressure < previousPressure - 2 { return " \u{2193}" }
        return ""
    }

    var memoryLabel: String {
        if memoryPressure >= 80 { return "CRITICAL" }
        if memoryPressure >= 60 { return "WARNING" }
        return "OK"
    }

    var memoryColor: Color {
        if memoryPressure >= 80 { return .red }
        if memoryPressure >= 60 { return .orange }
        return .green
    }

    var orphanCount: Int {
        processes.filter { $0.isOrphan }.count
    }

    var swapFormatted: String {
        if swapUsageMB >= 1024 {
            let gb = Double(swapUsageMB) / 1024.0
            return String(format: "%.1f GB", gb)
        }
        return "\(swapUsageMB) MB"
    }

    var totalUsedMB: Int {
        systemProcesses.reduce(0) { $0 + $1.totalMB }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        debugLog("refresh() started")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            debugLog("Background: collecting memory...")
            let mem = getMemoryPressure()
            debugLog("Background: memory=\(mem)")
            let swap = getSwapUsageMB()
            debugLog("Background: swap=\(swap)")
            let procs = collectDevProcesses()
            debugLog("Background: processes=\(procs.count)")
            let pts = collectPorts()
            debugLog("Background: ports=\(pts.count)")
            let sysprocs = collectTopMemory()
            debugLog("Background: systemProcesses=\(sysprocs.count)")
            let paused = checkIsPaused()
            debugLog("Background: all data collected, dispatching to main")
            DispatchQueue.main.async {
                self?.previousPressure = self?.memoryPressure ?? 0
                self?.memoryPressure = mem
                if mem >= 80 && !(self?.hasNotifiedCritical ?? true) {
                    self?.hasNotifiedCritical = true
                    self?.sendMemoryNotification(pressure: mem)
                }
                if mem < 75 {
                    self?.hasNotifiedCritical = false
                }
                self?.swapUsageMB = swap
                self?.processes = procs
                self?.ports = pts
                self?.systemProcesses = sysprocs
                self?.isPaused = paused
                self?.isRefreshing = false
                self?.lastRefresh = Date()
                debugLog("Main: updated all @Published properties, mem=\(mem), procs=\(procs.count)")
            }
        }
    }

    func killProcess(pid: Int) {
        killingPIDs.insert(pid)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = runShellCommand("kill -15 \(pid)")
            // Wait up to 3 seconds for graceful exit
            for _ in 0..<30 {
                usleep(100_000) // 100ms
                let check = runShellCommand("kill -0 \(pid) 2>/dev/null; echo $?")
                if check == "1" { break }
            }
            // Force kill if still alive
            _ = runShellCommand("kill -9 \(pid) 2>/dev/null")
            // Clean from orphan tracking
            let stateFile = NSString(string: "~/.config/devmon/state/orphans.txt").expandingTildeInPath
            _ = runShellCommand("sed -i '' '/^\(pid) /d' \(stateFile) 2>/dev/null")

            DispatchQueue.main.async {
                self?.killingPIDs.remove(pid)
                self?.refresh()
            }
        }
    }

    func killAllOrphans() {
        let orphans = processes.filter { $0.isOrphan }
        for orphan in orphans {
            killingPIDs.insert(orphan.pid)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for orphan in orphans {
                _ = runShellCommand("kill -15 \(orphan.pid)")
            }
            usleep(2_000_000) // 2 seconds
            for orphan in orphans {
                _ = runShellCommand("kill -9 \(orphan.pid) 2>/dev/null")
            }
            let stateFile = NSString(string: "~/.config/devmon/state/orphans.txt").expandingTildeInPath
            for orphan in orphans {
                _ = runShellCommand("sed -i '' '/^\(orphan.pid) /d' \(stateFile) 2>/dev/null")
            }
            DispatchQueue.main.async {
                self?.killingPIDs = []
                self?.refresh()
            }
        }
    }

    func killSystemProcess(pids: [Int]) {
        for pid in pids {
            killingPIDs.insert(pid)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // SIGTERM all pids
            for pid in pids {
                _ = runShellCommand("kill -15 \(pid)")
            }
            // Wait 2 seconds
            usleep(2_000_000)
            // SIGKILL remaining
            for pid in pids {
                _ = runShellCommand("kill -9 \(pid) 2>/dev/null")
            }
            DispatchQueue.main.async {
                for pid in pids {
                    self?.killingPIDs.remove(pid)
                }
                self?.refresh()
            }
        }
    }

    func togglePause() {
        guard let path = devmonPath() else { return }
        if isPaused {
            _ = runShellCommand("\(path) resume")
        } else {
            _ = runShellCommand("\(path) pause")
        }
        isPaused = !isPaused
    }

    func sendMemoryNotification(pressure: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "DevMon: High Memory"
            content.body = "Memory pressure at \(pressure)%. Consider closing unused apps."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "devmon-memory-\(pressure)", content: content, trigger: nil)
            center.add(request)
        }
    }
}

// MARK: - SwiftUI Views

struct DevMonPopoverView: View {
    @ObservedObject var viewModel: DevMonViewModel
    var onClose: () -> Void
    @State private var processesExpanded = false
    @State private var topMemoryExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    memorySection
                    systemMemorySection
                    processSection
                    portSection
                    actionsSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Divider()
            footerSection
        }
        .frame(width: 340)
        .frame(maxHeight: 560)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text("DevMon")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isRefreshing)
            .help("Refresh")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memory")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(viewModel.memoryPressure)%\(viewModel.memoryTrend)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.memoryColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(viewModel.memoryColor)
                        .frame(width: geo.size.width * CGFloat(min(viewModel.memoryPressure, 100)) / 100.0, height: 8)
                }
            }
            .frame(height: 8)

            HStack {
                Text(viewModel.memoryLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(viewModel.memoryColor)
                Spacer()
                Text("Swap: \(viewModel.swapFormatted)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - System Memory

    private var systemMemorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top Memory \u{2014} \(String(format: "%.1f", Double(viewModel.totalUsedMB) / 1024.0)) / \(String(format: "%.0f", viewModel.physicalMemoryGB)) GB")
                .font(.system(size: 12, weight: .semibold))

            if viewModel.systemProcesses.isEmpty {
                Text("Loading...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                let displayedSystemProcesses = topMemoryExpanded ? viewModel.systemProcesses : Array(viewModel.systemProcesses.prefix(5))
                VStack(spacing: 0) {
                    ForEach(Array(displayedSystemProcesses.enumerated()), id: \.element.id) { index, proc in
                        systemProcessRow(proc)
                        if index < displayedSystemProcesses.count - 1 {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                if viewModel.systemProcesses.count > 5 {
                    Button(action: { topMemoryExpanded.toggle() }) {
                        Text(topMemoryExpanded ? "Show less" : "Show \(viewModel.systemProcesses.count - 5) more...")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func systemProcessRow(_ proc: SystemProcess) -> some View {
        HStack(spacing: 6) {
            // Color bar proportional to memory
            RoundedRectangle(cornerRadius: 2)
                .fill(memoryBarColor(proc.totalMB))
                .frame(width: 3, height: 20)

            Text(proc.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if proc.processCount > 1 {
                Text("×\(proc.processCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Text(formatMemory(proc.totalMB))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(memoryBarColor(proc.totalMB))

            if !protectedProcesses.contains(proc.id) {
                let isKilling = proc.pids.contains(where: { viewModel.killingPIDs.contains($0) })
                Button(action: { viewModel.killSystemProcess(pids: proc.pids) }) {
                    Text(isKilling ? "Killing..." : "Kill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
                .disabled(isKilling)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func memoryBarColor(_ mb: Int) -> Color {
        if mb >= 2048 { return .red }
        if mb >= 512 { return .orange }
        return .secondary
    }

    private func formatMemory(_ mb: Int) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }

    // MARK: - Processes

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Processes")
                    .font(.system(size: 12, weight: .semibold))
                if viewModel.orphanCount > 0 {
                    Text("(\(viewModel.orphanCount) orphaned)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                Spacer()
            }

            if viewModel.processes.isEmpty {
                Text("No dev processes running")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                let displayedProcesses = processesExpanded ? viewModel.processes : Array(viewModel.processes.prefix(3))
                VStack(spacing: 0) {
                    ForEach(Array(displayedProcesses.enumerated()), id: \.element.id) { index, proc in
                        processRow(proc)
                        if index < displayedProcesses.count - 1 {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                if viewModel.processes.count > 3 {
                    Button(action: { processesExpanded.toggle() }) {
                        Text(processesExpanded ? "Show less" : "Show \(viewModel.processes.count - 3) more...")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                }

                if viewModel.orphanCount > 0 {
                    Button(action: { viewModel.killAllOrphans() }) {
                        HStack {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                            Text("Kill All Orphans")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
        }
    }

    private func processRow(_ proc: DevProcess) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(proc.statusEmoji)
                    .font(.system(size: 10))
                Text(proc.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text("PID \(proc.pid)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                if let port = proc.port {
                    detailBadge(":\(port)")
                }
                if let age = proc.orphanAgeFormatted {
                    detailBadge(age)
                }
                if proc.connections > 0 {
                    detailBadge("\(proc.connections) conn")
                }
                detailBadge("\(proc.memoryMB) MB")
                Spacer()
            }

            HStack {
                if !proc.isOrphan {
                    Text("attached")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                }
                Spacer()

                let isKilling = viewModel.killingPIDs.contains(proc.pid)
                Button(action: { viewModel.killProcess(pid: proc.pid) }) {
                    Text(isKilling ? "Killing..." : "Kill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
                .disabled(isKilling)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func detailBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(3)
    }

    // MARK: - Ports

    private var portSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Listening Ports")
                .font(.system(size: 12, weight: .semibold))

            if viewModel.ports.isEmpty {
                Text("No ports in 3000-9000 range")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.ports.enumerated()), id: \.element.id) { index, port in
                        portRow(port)
                        if index < viewModel.ports.count - 1 {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    private func portRow(_ port: DevPort) -> some View {
        HStack {
            Text(":\(port.port)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 50, alignment: .leading)
            Text(port.processName)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if port.connections == 0 {
                Text("stale")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(3)
            } else {
                Text("\(port.connections) conn")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            let isKilling = viewModel.killingPIDs.contains(port.pid)
            Button(action: { viewModel.killProcess(pid: port.pid) }) {
                Text(isKilling ? "Killing..." : "Kill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.red)
            .disabled(isKilling)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 8) {
            Button(action: {
                guard let path = devmonPath() else { return }
                runInTerminal("\(path) clean --dry-run")
            }) {
                Label("Clean Caches", systemImage: "trash.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: {
                guard let path = devmonPath() else { return }
                runInTerminal("\(path) log")
            }) {
                Label("View Log", systemImage: "doc.text")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(action: { viewModel.togglePause() }) {
                Label(viewModel.isPaused ? "Resume" : "Pause",
                      systemImage: viewModel.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                Circle()
                    .fill(viewModel.isPaused ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(viewModel.isPaused ? "Monitor: Paused" : "Monitor: Active")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text(relativeTime(from: viewModel.lastRefresh, to: context.date))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func relativeTime(from start: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        if seconds < 5 { return "Updated just now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        return "Updated \(seconds / 60)m ago"
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var viewModel = DevMonViewModel()
    var refreshTimer: Timer?
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "DM"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.behavior = .transient
        updatePopoverContent()

        // First refresh after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.viewModel.refresh()
        }

        // Periodic refresh
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshStatusBar()
        }

        // Global keyboard shortcut: Cmd+Shift+M
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers == "m" {
                DispatchQueue.main.async {
                    self?.togglePopover(nil)
                }
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers == "m" {
                DispatchQueue.main.async {
                    self?.togglePopover(nil)
                }
                return nil
            }
            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    func updatePopoverContent() {
        let contentView = DevMonPopoverView(viewModel: viewModel, onClose: { [weak self] in
            self?.closePopover()
        })
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        // Recreate content to ensure fresh SwiftUI observation binding
        updatePopoverContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        viewModel.refresh()

        // Monitor for clicks outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func refreshStatusBar() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pressure = getMemoryPressure()
            DispatchQueue.main.async {
                self?.updateIcon(pressure: pressure)
            }
        }
    }

    func updateIcon(pressure: Int) {
        guard let button = statusItem.button else { return }
        let indicator: String
        if pressure >= 80 {
            indicator = "\u{1F534}"
        } else if pressure >= 60 {
            indicator = "\u{1F7E1}"
        } else {
            indicator = "\u{1F7E2}"
        }
        button.title = "\(indicator) \(pressure)%\(viewModel.memoryTrend)"
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
