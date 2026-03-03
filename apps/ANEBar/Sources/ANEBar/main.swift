import AppKit
import Darwin
import Foundation

private struct LiveMetricsSample {
    var timestamp: Date
    var totalCPUUsage: Double
    var pCoreUsage: Double
    var eCoreUsage: Double
    var memoryUsage: Double
    var load1m: Double
    var aneUtilization: Double?
    var aneTFLOPS: Double?
    var runActive: Bool
}

private final class SystemMetricsSampler {
    private var previousTicks: [[UInt64]]?
    private let configuredPCoreCount: Int
    private let configuredECoreCount: Int

    init() {
        configuredPCoreCount = max(0, Self.readSysctlInt("hw.perflevel0.physicalcpu"))
        configuredECoreCount = max(0, Self.readSysctlInt("hw.perflevel1.physicalcpu"))
    }

    func sampleCPU() -> (total: Double, pCores: Double, eCores: Double)? {
        var cpuInfo: processor_info_array_t?
        var cpuCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0

        let status = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &infoCount
        )
        guard status == KERN_SUCCESS, let rawInfo = cpuInfo else {
            return nil
        }

        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: rawInfo)), size)
        }

        let coreCount = Int(cpuCount)
        let stride = Int(CPU_STATE_MAX)
        var ticks = Array(repeating: Array(repeating: UInt64(0), count: stride), count: coreCount)

        for core in 0..<coreCount {
            let base = core * stride
            ticks[core][Int(CPU_STATE_USER)] = UInt64(rawInfo[base + Int(CPU_STATE_USER)])
            ticks[core][Int(CPU_STATE_SYSTEM)] = UInt64(rawInfo[base + Int(CPU_STATE_SYSTEM)])
            ticks[core][Int(CPU_STATE_NICE)] = UInt64(rawInfo[base + Int(CPU_STATE_NICE)])
            ticks[core][Int(CPU_STATE_IDLE)] = UInt64(rawInfo[base + Int(CPU_STATE_IDLE)])
        }

        guard let previousTicks else {
            self.previousTicks = ticks
            return nil
        }

        var perCoreUsage = Array(repeating: 0.0, count: coreCount)
        for core in 0..<coreCount {
            let userDelta = ticks[core][Int(CPU_STATE_USER)] - previousTicks[core][Int(CPU_STATE_USER)]
            let systemDelta = ticks[core][Int(CPU_STATE_SYSTEM)] - previousTicks[core][Int(CPU_STATE_SYSTEM)]
            let niceDelta = ticks[core][Int(CPU_STATE_NICE)] - previousTicks[core][Int(CPU_STATE_NICE)]
            let idleDelta = ticks[core][Int(CPU_STATE_IDLE)] - previousTicks[core][Int(CPU_STATE_IDLE)]

            let active = Double(userDelta + systemDelta + niceDelta)
            let total = active + Double(idleDelta)
            perCoreUsage[core] = total > 0 ? (active / total) * 100.0 : 0
        }

        self.previousTicks = ticks

        guard !perCoreUsage.isEmpty else {
            return nil
        }

        let totalUsage = perCoreUsage.reduce(0, +) / Double(perCoreUsage.count)
        let split = coreSplit(totalCores: perCoreUsage.count)
        let pSlice = perCoreUsage.prefix(split.p)
        let eSlice = perCoreUsage.dropFirst(split.p).prefix(split.e)
        let pUsage = pSlice.isEmpty ? totalUsage : (pSlice.reduce(0, +) / Double(pSlice.count))
        let eUsage = eSlice.isEmpty ? totalUsage : (eSlice.reduce(0, +) / Double(eSlice.count))
        return (total: totalUsage, pCores: pUsage, eCores: eUsage)
    }

    func sampleMemoryPercent() -> Double {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let status = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            return 0
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        let usedPages = vmStats.active_count + vmStats.inactive_count + vmStats.wire_count + vmStats.compressor_page_count
        let used = Double(usedPages) * Double(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else {
            return 0
        }
        return clampPercent((used / total) * 100.0)
    }

    func sampleLoadAverage1m() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, Int32(loads.count))
        guard count > 0 else {
            return 0
        }
        return max(0, loads[0])
    }

    private func coreSplit(totalCores: Int) -> (p: Int, e: Int) {
        if configuredPCoreCount + configuredECoreCount == totalCores {
            return (configuredPCoreCount, configuredECoreCount)
        }
        if configuredPCoreCount > 0, configuredECoreCount == 0 {
            return (min(configuredPCoreCount, totalCores), max(0, totalCores - configuredPCoreCount))
        }
        if configuredECoreCount > 0, configuredPCoreCount == 0 {
            return (max(0, totalCores - configuredECoreCount), min(configuredECoreCount, totalCores))
        }
        let pGuess = max(1, totalCores / 2)
        return (pGuess, max(0, totalCores - pGuess))
    }

    private static func readSysctlInt(_ key: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = key.withCString { name in
            sysctlbyname(name, &value, &size, nil, 0)
        }
        guard result == 0 else {
            return 0
        }
        return Int(value)
    }

    private func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

private final class LiveMetricsMenuView: NSView {
    private var history: [LiveMetricsSample] = []
    private let maxPoints = 100

    override var intrinsicContentSize: NSSize {
        NSSize(width: 360, height: 220)
    }

    func push(_ sample: LiveMetricsSample) {
        history.append(sample)
        if history.count > maxPoints {
            history.removeFirst(history.count - maxPoints)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let latest = history.last else { return }
        let inset = bounds.insetBy(dx: 12, dy: 10)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        NSString(string: "Live Silicon Graph").draw(
            at: NSPoint(x: inset.minX, y: inset.maxY - 16),
            withAttributes: headerAttributes
        )

        drawProgressRow(
            label: "P-Cores",
            valueText: percentText(latest.pCoreUsage),
            value: latest.pCoreUsage,
            color: .systemOrange,
            row: 0,
            in: inset,
            attributes: textAttributes
        )
        drawProgressRow(
            label: "E-Cores",
            valueText: percentText(latest.eCoreUsage),
            value: latest.eCoreUsage,
            color: .systemBlue,
            row: 1,
            in: inset,
            attributes: textAttributes
        )
        drawProgressRow(
            label: "Memory",
            valueText: percentText(latest.memoryUsage),
            value: latest.memoryUsage,
            color: .systemTeal,
            row: 2,
            in: inset,
            attributes: textAttributes
        )

        let aneValue = latest.aneUtilization
        let aneText = aneValue.map(percentText) ?? "n/a"
        drawProgressRow(
            label: "ANE(run)",
            valueText: aneText,
            value: aneValue ?? 0,
            color: .systemGreen,
            row: 3,
            in: inset,
            attributes: textAttributes,
            dimmed: aneValue == nil
        )

        let tflopsText: String
        if let tflops = latest.aneTFLOPS {
            tflopsText = String(format: "ANE TFLOPS %.2f", tflops)
        } else {
            tflopsText = "ANE TFLOPS n/a"
        }
        let footerText = String(format: "Load %.2f | CPU %.1f%% | %@", latest.load1m, latest.totalCPUUsage, tflopsText)
        NSString(string: footerText).draw(
            at: NSPoint(x: inset.minX, y: inset.minY + 80),
            withAttributes: textAttributes
        )

        let graphRect = NSRect(x: inset.minX, y: inset.minY + 6, width: inset.width, height: 66)
        drawGraph(in: graphRect)
    }

    private func drawProgressRow(
        label: String,
        valueText: String,
        value: Double,
        color: NSColor,
        row: Int,
        in rect: NSRect,
        attributes: [NSAttributedString.Key: Any],
        dimmed: Bool = false
    ) {
        let rowTop = rect.maxY - 38 - CGFloat(row) * 22
        let labelWidth: CGFloat = 70
        let valueWidth: CGFloat = 52
        let barX = rect.minX + labelWidth + 8
        let barWidth = rect.width - labelWidth - valueWidth - 20
        let barRect = NSRect(x: barX, y: rowTop - 2, width: barWidth, height: 10)

        NSString(string: label).draw(
            at: NSPoint(x: rect.minX, y: rowTop - 4),
            withAttributes: attributes
        )
        NSString(string: valueText).draw(
            at: NSPoint(x: barRect.maxX + 8, y: rowTop - 4),
            withAttributes: attributes
        )

        let backgroundPath = NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.18).setFill()
        backgroundPath.fill()

        let fillRatio = CGFloat(min(100, max(0, value)) / 100.0)
        let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: barRect.width * fillRatio, height: barRect.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4)
        let alpha = dimmed ? 0.25 : 0.95
        color.withAlphaComponent(alpha).setFill()
        fillPath.fill()
    }

    private func drawGraph(in rect: NSRect) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()

        drawHorizontalGridLines(in: rect)
        drawSeries(values: history.map(\.pCoreUsage), color: .systemOrange, in: rect)
        drawSeries(values: history.map(\.eCoreUsage), color: .systemBlue, in: rect)
        drawSeries(values: history.map(\.memoryUsage), color: .systemTeal, in: rect)
        if history.contains(where: { $0.aneUtilization != nil }) {
            drawSeries(values: history.map { $0.aneUtilization ?? 0 }, color: .systemGreen.withAlphaComponent(0.8), in: rect)
        }
    }

    private func drawHorizontalGridLines(in rect: NSRect) {
        let levels: [CGFloat] = [0.25, 0.5, 0.75]
        NSColor.tertiaryLabelColor.withAlphaComponent(0.12).setStroke()
        for level in levels {
            let y = rect.minY + rect.height * level
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: y))
            line.line(to: NSPoint(x: rect.maxX, y: y))
            line.lineWidth = 1
            line.stroke()
        }
    }

    private func drawSeries(values: [Double], color: NSColor, in rect: NSRect) {
        guard values.count > 1 else { return }
        let stepX = rect.width / CGFloat(max(1, values.count - 1))
        let path = NSBezierPath()

        for (index, value) in values.enumerated() {
            let normalized = CGFloat(min(100, max(0, value)) / 100.0)
            let point = NSPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.minY + normalized * rect.height
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }

        color.setStroke()
        path.lineWidth = 1.7
        path.stroke()
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

private func discoverModelArtifacts(in repoRoot: String) -> [String] {
    let fileManager = FileManager.default
    let rootURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
    let modelExtensions: Set<String> = [
        "bin",
        "gguf",
        "mlmodel",
        "mlpackage",
        "onnx",
        "pt",
        "pth",
        "safetensors",
    ]
    let skipDirectories: Set<String> = [
        ".build",
        ".git",
        ".private",
        "build",
        "dist",
    ]

    var results: [String] = []

    guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return results
    }

    while let next = enumerator.nextObject() as? URL {
        let relativePath = next.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        let components = Set(relativePath.split(separator: "/").map(String.init))
        if !components.isDisjoint(with: skipDirectories) {
            if let values = try? next.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                enumerator.skipDescendants()
            }
            continue
        }

        let values = try? next.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let isDirectory = values?.isDirectory == true
        let isRegularFile = values?.isRegularFile == true

        if isDirectory, next.pathExtension.lowercased() == "mlpackage" {
            results.append(relativePath)
            enumerator.skipDescendants()
            continue
        }

        guard isRegularFile else {
            continue
        }

        let ext = next.pathExtension.lowercased()
        if modelExtensions.contains(ext) {
            results.append(relativePath)
        }
    }

    results.sort()
    return results
}

@MainActor
final class ANEBarController: NSObject, NSApplicationDelegate {
    private enum DefaultsKey {
        static let repoRoot = "ane_repo_root"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var runFastItem = NSMenuItem()
    private var runFullItem = NSMenuItem()
    private var statusLineItem = NSMenuItem()
    private var repoLineItem = NSMenuItem()
    private var modelSummaryItem = NSMenuItem()
    private var modelDetailItems: [NSMenuItem] = []
    private var metricsView = LiveMetricsMenuView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
    private var process: Process?
    private var lastExitCode: Int32?
    private var metricsSampler = SystemMetricsSampler()
    private var metricsTimer: Timer?
    private var latestMetrics: LiveMetricsSample?
    private var processOutputBuffer = ""
    private var lastANEUtilization: Double?
    private var lastANETflops: Double?
    private var lastANEUpdateAt: Date?
    private var trackedModels: [String] = []
    private var metricsTick: Int = 0
    private var modelRefreshInFlight = false

    private var repoRoot: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: DefaultsKey.repoRoot), !saved.isEmpty {
                return saved
            }
            let fallback = NSString(string: "~/Development/AIFLOWLABS/deep_learning/ANE").expandingTildeInPath
            return ProcessInfo.processInfo.environment["ANE_REPO_PATH"] ?? fallback
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.repoRoot)
            refreshInfoLines()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupMenu()
        refreshInfoLines()
        startMetricsLoop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        metricsTimer?.invalidate()
        metricsTimer = nil
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.title = "ANE"
            button.toolTip = "ANEBar"
            if let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "ANEBar") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            }
        }
        statusItem.menu = menu
    }

    private func setupMenu() {
        let titleItem = NSMenuItem(title: "ANEBar", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let metricsItem = NSMenuItem()
        metricsItem.view = metricsView
        menu.addItem(metricsItem)
        menu.addItem(.separator())

        statusLineItem = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        repoLineItem = NSMenuItem(title: "Repo: \(repoRoot)", action: nil, keyEquivalent: "")
        repoLineItem.isEnabled = false
        menu.addItem(repoLineItem)

        modelSummaryItem = NSMenuItem(title: "Models tracked: scanning…", action: nil, keyEquivalent: "")
        modelSummaryItem.isEnabled = false
        menu.addItem(modelSummaryItem)

        for _ in 0..<5 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.isHidden = true
            modelDetailItems.append(item)
            menu.addItem(item)
        }

        let refreshModelsItem = NSMenuItem(title: "Refresh Model Index", action: #selector(refreshModelIndexManual), keyEquivalent: "m")
        refreshModelsItem.target = self
        menu.addItem(refreshModelsItem)

        menu.addItem(.separator())

        runFastItem = NSMenuItem(title: "Run Fast Pipeline", action: #selector(runFastPipeline), keyEquivalent: "r")
        runFastItem.target = self
        menu.addItem(runFastItem)

        runFullItem = NSMenuItem(title: "Run Full Pipeline", action: #selector(runFullPipeline), keyEquivalent: "R")
        runFullItem.target = self
        menu.addItem(runFullItem)

        let stopItem = NSMenuItem(title: "Stop Running Job", action: #selector(stopJob), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let openResultsItem = NSMenuItem(title: "Open Results Folder", action: #selector(openResultsFolder), keyEquivalent: "o")
        openResultsItem.target = self
        menu.addItem(openResultsItem)

        let openHeroItem = NSMenuItem(title: "Open Hero Graphic", action: #selector(openHeroGraphic), keyEquivalent: "h")
        openHeroItem.target = self
        menu.addItem(openHeroItem)

        let openSignalItem = NSMenuItem(title: "Open Community Spotlight Graphic", action: #selector(openSpotlightGraphic), keyEquivalent: "g")
        openSignalItem.target = self
        menu.addItem(openSignalItem)

        let copyPostItem = NSMenuItem(title: "Copy Today Post", action: #selector(copyTodayPost), keyEquivalent: "c")
        copyPostItem.target = self
        menu.addItem(copyPostItem)

        menu.addItem(.separator())

        let chooseRepoItem = NSMenuItem(title: "Choose Repo Root…", action: #selector(chooseRepoRoot), keyEquivalent: "")
        chooseRepoItem.target = self
        menu.addItem(chooseRepoItem)

        let quitItem = NSMenuItem(title: "Quit ANEBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func refreshInfoLines() {
        repoLineItem.title = "Repo: \(repoRoot)"
        if let code = lastExitCode {
            statusLineItem.title = code == 0 ? "Status: last run succeeded" : "Status: last run failed (\(code))"
        }
        refreshModelIndex(force: true)
    }

    private func setRunning(_ running: Bool, message: String) {
        runFastItem.isEnabled = !running
        runFullItem.isEnabled = !running
        statusLineItem.title = "Status: \(message)"
        updateStatusButton()
    }

    private func runPipeline(qosRuns: Int, skipBuild: Bool) {
        guard process == nil else { return }

        let command = "uv run python training/research/run_research.py --qos-runs \(qosRuns) \(skipBuild ? "--skip-build" : "")"
        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-lc", command]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor in
                self?.consumeProcessOutput(chunk)
            }
        }

        setRunning(true, message: skipBuild ? "running fast pipeline" : "running full pipeline")
        process = proc

        proc.terminationHandler = { [weak self, weak pipe] finished in
            Task { @MainActor in
                pipe?.fileHandleForReading.readabilityHandler = nil
                self?.lastExitCode = finished.terminationStatus
                self?.process = nil
                let ok = finished.terminationStatus == 0
                self?.setRunning(false, message: ok ? "idle" : "error")
                self?.refreshInfoLines()
            }
        }

        do {
            try proc.run()
        } catch {
            process = nil
            setRunning(false, message: "launch failed")
            lastExitCode = 1
            refreshInfoLines()
        }
    }

    @objc private func runFastPipeline() {
        runPipeline(qosRuns: 2, skipBuild: true)
    }

    @objc private func runFullPipeline() {
        runPipeline(qosRuns: 3, skipBuild: false)
    }

    @objc private func stopJob() {
        process?.terminate()
    }

    @objc private func openResultsFolder() {
        let path = "\(repoRoot)/training/research/results"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openHeroGraphic() {
        let path = "\(repoRoot)/training/research/results/figures/ane_hero_card_instagram.png"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openSpotlightGraphic() {
        let path = "\(repoRoot)/training/research/results/figures/ecosystem_spotlight_card_instagram.png"
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func copyTodayPost() {
        let path = "\(repoRoot)/training/research/results/content/today_post_premium.md"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            statusLineItem.title = "Status: could not read today post"
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        statusLineItem.title = "Status: today post copied"
    }

    @objc private func chooseRepoRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: repoRoot)

        if panel.runModal() == .OK, let url = panel.url {
            repoRoot = url.path
            statusLineItem.title = "Status: repo updated"
            refreshModelIndex(force: true)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func refreshModelIndexManual() {
        refreshModelIndex(force: true)
    }

    private func startMetricsLoop() {
        metricsTimer?.invalidate()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMetrics()
            }
        }
        if let timer = metricsTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        refreshMetrics()
    }

    private func refreshMetrics() {
        metricsTick += 1
        if metricsTick % 20 == 0 {
            refreshModelIndex(force: false)
        }
        guard let cpu = metricsSampler.sampleCPU() else {
            return
        }
        let memory = metricsSampler.sampleMemoryPercent()
        let load1m = metricsSampler.sampleLoadAverage1m()
        let sample = LiveMetricsSample(
            timestamp: Date(),
            totalCPUUsage: cpu.total,
            pCoreUsage: cpu.pCores,
            eCoreUsage: cpu.eCores,
            memoryUsage: memory,
            load1m: load1m,
            aneUtilization: activeANEUtilization(),
            aneTFLOPS: activeANETflops(),
            runActive: process != nil
        )
        latestMetrics = sample
        metricsView.push(sample)
        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }
        guard let latestMetrics else {
            button.title = process == nil ? "ANE" : "ANE*"
            return
        }

        let prefix = process == nil ? "ANE" : "ANE*"
        button.title = String(format: "%@ %.0f/%.0f", prefix, latestMetrics.pCoreUsage, latestMetrics.eCoreUsage)
        button.toolTip = String(
            format: "P %.1f%%  E %.1f%%  Mem %.1f%%  Load %.2f",
            latestMetrics.pCoreUsage,
            latestMetrics.eCoreUsage,
            latestMetrics.memoryUsage,
            latestMetrics.load1m
        )
    }

    private func consumeProcessOutput(_ chunk: String) {
        processOutputBuffer.append(chunk)
        while let newline = processOutputBuffer.range(of: "\n") {
            let line = String(processOutputBuffer[..<newline.lowerBound])
            processOutputBuffer.removeSubrange(..<newline.upperBound)
            parseMetricsLine(line)
        }
    }

    private func parseMetricsLine(_ line: String) {
        if let util = captureDouble(in: line, pattern: #"ANE utilization:\s*([0-9]+(?:\.[0-9]+)?)%"#) {
            lastANEUtilization = util
            lastANEUpdateAt = Date()
        }
        if let tflops = captureDouble(in: line, pattern: #"ANE TFLOPS:\s*([0-9]+(?:\.[0-9]+)?)"#) {
            lastANETflops = tflops
            lastANEUpdateAt = Date()
        }
    }

    private func activeANEUtilization() -> Double? {
        guard let timestamp = lastANEUpdateAt else {
            return nil
        }
        // Treat ANE metrics as stale if they were not refreshed recently.
        if Date().timeIntervalSince(timestamp) > 30 * 60 {
            return nil
        }
        return lastANEUtilization
    }

    private func activeANETflops() -> Double? {
        guard let timestamp = lastANEUpdateAt else {
            return nil
        }
        if Date().timeIntervalSince(timestamp) > 30 * 60 {
            return nil
        }
        return lastANETflops
    }

    private func captureDouble(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }
        let valueRange = match.range(at: 1)
        guard let swiftRange = Range(valueRange, in: text) else {
            return nil
        }
        return Double(text[swiftRange])
    }

    private func refreshModelIndex(force: Bool) {
        if modelRefreshInFlight {
            return
        }
        modelRefreshInFlight = true
        let root = repoRoot
        Task.detached(priority: .utility) {
            let models = discoverModelArtifacts(in: root)
            await MainActor.run { [weak self] in
                self?.applyTrackedModels(models)
                self?.modelRefreshInFlight = false
            }
        }
    }

    private func applyTrackedModels(_ models: [String]) {
        let previousCount = trackedModels.count
        trackedModels = models

        let shown = min(models.count, modelDetailItems.count)
        let suffix = models.count > shown ? " (showing \(shown))" : ""
        modelSummaryItem.title = "Models tracked: \(models.count)\(suffix)"

        for index in 0..<modelDetailItems.count {
            let item = modelDetailItems[index]
            if index < shown {
                let modelPath = models[index]
                item.title = "Model \(index + 1): \(URL(fileURLWithPath: modelPath).lastPathComponent)"
                item.toolTip = modelPath
                item.isHidden = false
            } else {
                item.title = ""
                item.toolTip = nil
                item.isHidden = true
            }
        }

        if previousCount != 0, previousCount != models.count {
            statusLineItem.title = "Status: model index updated (\(models.count))"
        }
    }
}

@main
struct ANEBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = ANEBarController()
        app.delegate = delegate
        app.run()
    }
}
