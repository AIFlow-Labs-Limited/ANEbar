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
    var telemetrySource: String
    var runActive: Bool
}

private struct ModelArtifact {
    var relativePath: String
    var fileExtension: String
    var sizeBytes: UInt64
    var modifiedAt: Date?
}

private struct ModelCatalog {
    var artifacts: [ModelArtifact]

    var totalCount: Int {
        artifacts.count
    }

    var totalSizeBytes: UInt64 {
        artifacts.reduce(0) { $0 + $1.sizeBytes }
    }

    var extensionCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for artifact in artifacts {
            counts[artifact.fileExtension, default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
    }

    func newest(limit: Int) -> [ModelArtifact] {
        artifacts
            .sorted { lhs, rhs in
                let left = lhs.modifiedAt ?? .distantPast
                let right = rhs.modifiedAt ?? .distantPast
                if left == right {
                    return lhs.relativePath < rhs.relativePath
                }
                return left > right
            }
            .prefix(limit)
            .map { $0 }
    }
}

private struct GitHeadInfo {
    var shortSHA: String
    var timestamp: Date
    var subject: String
}

private struct RunRecord: Codable {
    var id: String
    var mode: String
    var experimentID: String?
    var group: String?
    var title: String?
    var command: String
    var repoRoot: String
    var workingDirectory: String?
    var repoHead: String?
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: Double
    var exitCode: Int32
    var aneUtilization: Double?
    var aneTFLOPS: Double?
    var totalTFLOPS: Double?
    var avgTrainMS: Double?
    var telemetrySource: String?
}

private func anebarDataDirectory() -> URL {
    let fileManager = FileManager.default
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return appSupport.appendingPathComponent("ANEBar", isDirectory: true)
}

private struct QueueItem: Codable {
    var id: String
    var preset: String
    var experimentID: String?
    var title: String?
    var createdAt: Date
    var scheduledAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var state: String
    var exitCode: Int32?
}

private final class RunQueueStore {
    let fileURL: URL
    private(set) var items: [QueueItem] = []
    private let maxItems = 200

    init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("run_queue.json")
        load()
    }

    func enqueue(preset: RunPreset, delaySeconds: TimeInterval = 0) -> QueueItem {
        enqueue(preset: preset, experimentID: "preset.\(preset.rawValue)", title: preset.menuTitle, delaySeconds: delaySeconds)
    }

    func enqueue(experiment: ExperimentDefinition, delaySeconds: TimeInterval = 0) -> QueueItem {
        let title = delaySeconds > 0 ? "\(experiment.title) (+\(Int(delaySeconds / 60))m)" : experiment.title
        return enqueue(
            preset: .fast,
            experimentID: experiment.id,
            title: title,
            delaySeconds: delaySeconds
        )
    }

    private func enqueue(preset: RunPreset, experimentID: String?, title: String?, delaySeconds: TimeInterval) -> QueueItem {
        let now = Date()
        let item = QueueItem(
            id: UUID().uuidString,
            preset: preset.rawValue,
            experimentID: experimentID,
            title: title,
            createdAt: now,
            scheduledAt: now.addingTimeInterval(max(0, delaySeconds)),
            startedAt: nil,
            finishedAt: nil,
            state: "pending",
            exitCode: nil
        )
        items.append(item)
        trimAndSave()
        return item
    }

    func duePending(at now: Date = Date()) -> QueueItem? {
        items.first { $0.state == "pending" && $0.scheduledAt <= now }
    }

    func pendingCount() -> Int {
        items.filter { $0.state == "pending" }.count
    }

    func markRunning(id: String, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = "running"
        items[index].startedAt = date
        save()
    }

    func markFinished(id: String, exitCode: Int32, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = exitCode == 0 ? "done" : "failed"
        items[index].finishedAt = date
        items[index].exitCode = exitCode
        trimAndSave()
    }

    func cancelAllPending() {
        for index in items.indices where items[index].state == "pending" {
            items[index].state = "canceled"
            items[index].finishedAt = Date()
        }
        trimAndSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([QueueItem].self, from: data)
        } catch {
            items = []
        }
    }

    private func trimAndSave() {
        if items.count > maxItems {
            items.removeFirst(items.count - maxItems)
        }
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignore save failures.
        }
    }
}

private struct BatteryStatus {
    var percent: Int?
    var isCharging: Bool
    var raw: String
}

private final class RunHistoryStore {
    let baseDirectory: URL
    let fileURL: URL
    private(set) var records: [RunRecord] = []
    private let maxRecords = 500

    init(baseDirectory: URL = anebarDataDirectory()) {
        self.baseDirectory = baseDirectory
        fileURL = baseDirectory.appendingPathComponent("run_history.json")

        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            // Ignore and continue with best-effort persistence.
        }

        load()
    }

    func append(_ record: RunRecord) {
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        save()
    }

    func recent(limit: Int) -> [RunRecord] {
        Array(records.suffix(limit))
    }

    func recentDescending(limit: Int) -> [RunRecord] {
        recent(limit: limit).reversed()
    }

    func record(id: String) -> RunRecord? {
        records.last { $0.id == id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            records = []
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([RunRecord].self, from: data)
        } catch {
            records = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Ignore save failures; this should never crash the app.
        }
    }
}

private enum RunPreset: String {
    case fast
    case full
    case benchmark

    var displayTitle: String {
        switch self {
        case .fast:
            return "fast"
        case .full:
            return "full"
        case .benchmark:
            return "benchmark"
        }
    }

    var menuTitle: String {
        switch self {
        case .fast:
            return "Run Fast Preset"
        case .full:
            return "Run Full Preset"
        case .benchmark:
            return "Run Benchmark Preset"
        }
    }
}

private enum RepoProfileKind: String {
    case upstreamMainline = "upstream-mainline"
    case labEnhanced = "lab-enhanced"
    case customFork = "custom-fork"
}

private struct RepoProfile {
    var kind: RepoProfileKind
    var label: String
    var detail: String
}

private func detectRepoProfile(in repoRoot: String) -> RepoProfile {
    let fileManager = FileManager.default
    func has(_ relativePath: String) -> Bool {
        fileManager.fileExists(atPath: "\(repoRoot)/\(relativePath)")
    }

    let hasTraining = has("training/Makefile")
    let hasDynamic = has("training/training_dynamic/Makefile")
    let hasDashboard = has("training/dashboard.py")
    let hasResearch = has("training/research/run_research.py")
    let hasRootProbes = has("inmem_peak.m") || has("sram_probe.m")

    if hasResearch {
        return RepoProfile(
            kind: .labEnhanced,
            label: "lab-enhanced",
            detail: "Upstream ANE plus private research, charts, and post assets."
        )
    }

    if hasTraining || hasDynamic || hasDashboard || hasRootProbes {
        return RepoProfile(
            kind: .upstreamMainline,
            label: "upstream-mainline",
            detail: "Mainline ANE experiments without the private research stack."
        )
    }

    return RepoProfile(
        kind: .customFork,
        label: "custom-fork",
        detail: "Custom layout detected. Capabilities are inferred from files on disk."
    )
}

private enum ExperimentGroup: String, CaseIterable {
    case peak = "Peak"
    case training = "Training"
    case dynamic = "Dynamic"
    case validation = "Validation"
    case bridge = "Bridge"
    case lab = "Lab"

    var sortRank: Int {
        switch self {
        case .peak:
            return 0
        case .training:
            return 1
        case .dynamic:
            return 2
        case .validation:
            return 3
        case .bridge:
            return 4
        case .lab:
            return 5
        }
    }
}

private struct ExperimentDefinition {
    var id: String
    var title: String
    var summary: String
    var group: ExperimentGroup
    var workingDirectory: String
    var buildCommand: String?
    var runCommand: String?
    var telemetry: String
    var sourcePath: String?
    var requiresSudo: Bool = false
    var advanced: Bool = false

    var isRunnable: Bool {
        runCommand != nil
    }

    var runLabel: String {
        "\(group.rawValue.lowercased())/\(id)"
    }

    var metadataLine: String {
        var parts: [String] = ["Telemetry: \(telemetry)"]
        if requiresSudo {
            parts.append("sudo")
        }
        if advanced {
            parts.append("advanced")
        }
        if !isRunnable {
            parts.append("catalogued only")
        }
        if let sourcePath {
            parts.append(sourcePath)
        }
        return parts.joined(separator: " | ")
    }

    func resolvedWorkingDirectory(repoRoot: String) -> String {
        workingDirectory.replacingOccurrences(of: "{repo}", with: repoRoot)
    }

    func resolvedCommand(repoRoot: String) -> String? {
        guard let runCommand else {
            return nil
        }
        let build = buildCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if build.isEmpty || build == "true" {
            return runCommand
        }
        return "\(build) && \(runCommand)"
    }
}

private func missingPrerequisites(for experiment: ExperimentDefinition, repoRoot: String) -> [String] {
    let fileManager = FileManager.default
    func has(_ relativePath: String) -> Bool {
        fileManager.fileExists(atPath: "\(repoRoot)/\(relativePath)")
    }

    let command = experiment.resolvedCommand(repoRoot: repoRoot) ?? experiment.runCommand ?? ""
    var missing: [String] = []

    if command.contains("train_large") || command.contains("dashboard.py") {
        if !has("training/tinystories_data00.bin") {
            missing.append("training/tinystories_data00.bin")
        }
    }

    return missing
}

private func discoverExperimentCatalog(in repoRoot: String, profile: RepoProfile) -> [ExperimentDefinition] {
    let fileManager = FileManager.default
    func has(_ relativePath: String) -> Bool {
        fileManager.fileExists(atPath: "\(repoRoot)/\(relativePath)")
    }

    var experiments: [ExperimentDefinition] = []

    func appendIfPresent(
        _ relativePath: String,
        experiment: ExperimentDefinition
    ) {
        if has(relativePath) {
            experiments.append(experiment)
        }
    }

    appendIfPresent("inmem_basic.m", experiment: ExperimentDefinition(
        id: "inmem_basic",
        title: "In-memory Basic Probe",
        summary: "Quick sanity check for the in-memory ANE model path. Current local run fails at runtime on this machine.",
        group: .peak,
        workingDirectory: "{repo}",
        buildCommand: "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface -ldl -o inmem_basic inmem_basic.m",
        runCommand: "./inmem_basic",
        telemetry: "stdout summary",
        sourcePath: "inmem_basic.m",
        advanced: true
    ))
    appendIfPresent("inmem_peak.m", experiment: ExperimentDefinition(
        id: "inmem_peak",
        title: "In-memory Peak Throughput",
        summary: "High-signal peak probe for the strongest public ANE throughput clips. Verified locally around 7.25-10.91 TFLOPS.",
        group: .peak,
        workingDirectory: "{repo}",
        buildCommand: "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface -ldl -o inmem_peak inmem_peak.m",
        runCommand: "./inmem_peak",
        telemetry: "stdout summary",
        sourcePath: "inmem_peak.m"
    ))
    appendIfPresent("inmem_bench.m", experiment: ExperimentDefinition(
        id: "inmem_bench",
        title: "In-memory Benchmark Sweep",
        summary: "Broader in-memory benchmark sweep for throughput comparisons. Current local run returns FAIL(-1) across the sweep.",
        group: .peak,
        workingDirectory: "{repo}",
        buildCommand: "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework IOSurface -ldl -o inmem_bench inmem_bench.m",
        runCommand: "./inmem_bench",
        telemetry: "stdout summary",
        sourcePath: "inmem_bench.m"
    ))
    appendIfPresent("sram_bench.m", experiment: ExperimentDefinition(
        id: "sram_bench",
        title: "SRAM Benchmark",
        summary: "Benchmarks SRAM-oriented probe behavior on the current ANE family. Current local run returns FAIL(-1) across the sweep.",
        group: .peak,
        workingDirectory: "{repo}",
        buildCommand: "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface -ldl -o sram_bench sram_bench.m",
        runCommand: "./sram_bench",
        telemetry: "stdout summary",
        sourcePath: "sram_bench.m"
    ))
    appendIfPresent("sram_probe.m", experiment: ExperimentDefinition(
        id: "sram_probe",
        title: "SRAM Probe",
        summary: "Low-level SRAM probe useful for architecture exploration and failure reports. Current local run returns FAIL(-1) on this machine.",
        group: .peak,
        workingDirectory: "{repo}",
        buildCommand: "xcrun clang -O2 -Wall -fobjc-arc -framework Foundation -framework IOSurface -ldl -o sram_probe sram_probe.m",
        runCommand: "./sram_probe",
        telemetry: "stdout summary",
        sourcePath: "sram_probe.m",
        advanced: true
    ))

    appendIfPresent("training/train_large.m", experiment: ExperimentDefinition(
        id: "train_large",
        title: "Static Training Baseline",
        summary: "Mainline baseline training path with JSON step and perf telemetry on stderr. Requires local TinyStories data before it can run here.",
        group: .training,
        workingDirectory: "{repo}",
        buildCommand: "make -C training train_large",
        runCommand: "./training/train_large --steps 100 --lr 1e-4",
        telemetry: "stderr JSON + stdout summary",
        sourcePath: "training/train_large.m"
    ))
    appendIfPresent("training/train_large_ane.m", experiment: ExperimentDefinition(
        id: "train_large_ane",
        title: "Static Training + ANE Extras",
        summary: "Mainline training path with ANE-offloaded extras and final throughput summaries. Requires local TinyStories data before it can run here.",
        group: .training,
        workingDirectory: "{repo}",
        buildCommand: "make -C training train_large_ane",
        runCommand: "./training/train_large_ane --steps 100 --lr 1e-4",
        telemetry: "stdout summary",
        sourcePath: "training/train_large_ane.m"
    ))
    appendIfPresent("training/dashboard.py", experiment: ExperimentDefinition(
        id: "dashboard_ane",
        title: "Dashboard ANE Mode",
        summary: "Live terminal dashboard for the static path with optional powermetrics integration. Depends on the train_large prerequisites.",
        group: .training,
        workingDirectory: "{repo}/training",
        buildCommand: nil,
        runCommand: "uv run --with blessed --with psutil --with numpy python dashboard.py --ane",
        telemetry: "dashboard stream + powermetrics",
        sourcePath: "training/dashboard.py",
        requiresSudo: true
    ))

    appendIfPresent("training/training_dynamic/train.m", experiment: ExperimentDefinition(
        id: "train_dynamic",
        title: "Dynamic Training Pipeline",
        summary: "Mainline dynamic-weight training path for newer runtime exploration.",
        group: .dynamic,
        workingDirectory: "{repo}/training/training_dynamic",
        buildCommand: "make train",
        runCommand: "./train --steps 200 --lr 1e-4",
        telemetry: "stdout summary",
        sourcePath: "training/training_dynamic/train.m"
    ))
    appendIfPresent("training/dashboard.py", experiment: ExperimentDefinition(
        id: "dashboard_dynamic",
        title: "Dashboard Dynamic Mode",
        summary: "Runs the dashboard against the dynamic pipeline for live comparison.",
        group: .dynamic,
        workingDirectory: "{repo}/training",
        buildCommand: nil,
        runCommand: "uv run --with blessed --with psutil --with numpy python dashboard.py --dynamic",
        telemetry: "dashboard stream + powermetrics",
        sourcePath: "training/dashboard.py",
        requiresSudo: true
    ))
    appendIfPresent("training/dashboard.py", experiment: ExperimentDefinition(
        id: "dashboard_dynamic_no_generate",
        title: "Dashboard Dynamic (No Generate)",
        summary: "Dynamic dashboard without text sampling, useful for cleaner benchmark runs.",
        group: .dynamic,
        workingDirectory: "{repo}/training",
        buildCommand: nil,
        runCommand: "uv run --with blessed --with psutil --with numpy python dashboard.py --dynamic --no-generate",
        telemetry: "dashboard stream + powermetrics",
        sourcePath: "training/dashboard.py",
        requiresSudo: true,
        advanced: true
    ))

    let validationEntries: [(String, String, String)] = [
        ("test_rmsnorm_bwd", "RMSNorm Backward Validation", "Validates the ANE RMSNorm backward path."),
        ("test_classifier", "Classifier Validation", "Validates the ANE classifier path."),
        ("test_weight_reload", "Weight Reload Probe", "Tests whether weights can change without recompilation."),
        ("test_perf_stats", "Performance Stats Probe", "Checks the private perf-stats path on the current machine."),
        ("test_qos_sweep", "QoS Sweep", "Sweeps QoS settings to measure compile/load/eval behavior."),
        ("test_ane_advanced", "Advanced ANE Probe", "Explores private classes, weightsBuffer, and procedureIndex behavior."),
    ]

    for (id, title, summary) in validationEntries where has("training/\(id).m") {
        experiments.append(
            ExperimentDefinition(
                id: id,
                title: title,
                summary: summary,
                group: .validation,
                workingDirectory: "{repo}",
                buildCommand: "make -C training \(id)",
                runCommand: "./training/\(id)",
                telemetry: id == "test_qos_sweep" ? "stdout table" : "stdout summary",
                sourcePath: "training/\(id).m",
                advanced: id == "test_ane_advanced"
            )
        )
    }

    let sourceOnlyProbes: [(String, String, String)] = [
        ("test_dynamic_matmul", "Dynamic Matmul Standalone", "Catalogued probe in source; build recipe still needs wiring."),
        ("test_weight_patch", "Weight Patch Standalone", "Catalogued probe in source; build recipe still needs wiring."),
        ("test_ane_causal_attn", "ANE Causal Attention", "Catalogued probe in source; build recipe still needs wiring."),
        ("test_ane_sdpa5", "ANE SDPA", "Catalogued probe in source; build recipe still needs wiring."),
        ("test_conv_attn3", "Conv Attention", "Catalogued probe in source; build recipe still needs wiring."),
        ("test_full_fused", "Full Fused Probe", "Catalogued probe in source; build recipe still needs wiring."),
        ("test_fused_bwd", "Fused Backward Probe", "Catalogued probe in source; build recipe still needs wiring."),
        ("test_fused_qkv", "Fused QKV Probe", "Catalogued probe in source; build recipe still needs wiring."),
    ]
    for (id, title, summary) in sourceOnlyProbes where has("training/\(id).m") {
        experiments.append(
            ExperimentDefinition(
                id: id,
                title: title,
                summary: summary,
                group: .validation,
                workingDirectory: "{repo}",
                buildCommand: nil,
                runCommand: nil,
                telemetry: "catalogued only",
                sourcePath: "training/\(id).m",
                advanced: true
            )
        )
    }

    appendIfPresent("bridge/Makefile", experiment: ExperimentDefinition(
        id: "bridge_build",
        title: "Build Bridge dylib",
        summary: "Builds the native bridge layer for future integrations and runtime work.",
        group: .bridge,
        workingDirectory: "{repo}",
        buildCommand: "make -C bridge",
        runCommand: nil,
        telemetry: "build log",
        sourcePath: "bridge/Makefile",
        advanced: true
    ))

    if profile.kind == .labEnhanced, has("training/research/run_research.py") {
        experiments.append(
            ExperimentDefinition(
                id: "lab_research",
                title: "Lab Research Pipeline",
                summary: "Runs the private research stack that generates charts, reports, and social assets. This is a report pipeline, not a live ANE telemetry run.",
                group: .lab,
                workingDirectory: "{repo}",
                buildCommand: "uv sync",
                runCommand: "uv run python training/research/run_research.py --qos-runs 3",
                telemetry: "artifact report from probe logs",
                sourcePath: "training/research/run_research.py"
            )
        )
    }

    return experiments.sorted { lhs, rhs in
        if lhs.group == rhs.group {
            if lhs.advanced == rhs.advanced {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.advanced == false && rhs.advanced == true
        }
        return lhs.group.sortRank < rhs.group.sortRank
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func defaultShellEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let preferredPathParts = [
        "\(home)/.local/bin",
        "\(home)/.cargo/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    let existingParts = (environment["PATH"] ?? "")
        .split(separator: ":")
        .map(String.init)
    var mergedPath = preferredPathParts
    for part in existingParts where !mergedPath.contains(part) {
        mergedPath.append(part)
    }
    environment["PATH"] = mergedPath.joined(separator: ":")
    return environment
}

private func cleanShellOutput(_ text: String) -> String {
    let noisePatterns = [
        ".bash_profile: line",
        "cargo/env: No such file or directory",
    ]
    let lines = text
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return false
            }
            return !noisePatterns.contains(where: { trimmed.contains($0) })
        }
    return lines.joined(separator: "\n")
}

private func runShellCommand(_ command: String) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.environment = defaultShellEnvironment()

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    do {
        try process.run()
    } catch {
        return (status: 1, output: "")
    }

    process.waitUntilExit()
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let rawText = String(data: data, encoding: .utf8) ?? ""
    let text = cleanShellOutput(rawText)
    return (status: process.terminationStatus, output: text)
}

private func readGitHeadInfo(in repoRoot: String) -> GitHeadInfo? {
    let quoted = shellQuote(repoRoot)
    let command = "git -C \(quoted) log -1 --pretty=%h\\|%ct\\|%s"
    let result = runShellCommand(command)
    guard result.status == 0 else {
        return nil
    }
    let line = result.output
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .reversed()
        .first(where: { $0.contains("|") })?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let components = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
    guard components.count == 3,
          let epoch = TimeInterval(components[1])
    else {
        return nil
    }
    return GitHeadInfo(
        shortSHA: String(components[0]),
        timestamp: Date(timeIntervalSince1970: epoch),
        subject: String(components[2])
    )
}

private func readGitDirty(in repoRoot: String) -> Bool {
    let quoted = shellQuote(repoRoot)
    let command = "git -C \(quoted) status --porcelain"
    let result = runShellCommand(command)
    guard result.status == 0 else {
        return false
    }
    return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func readGitAheadBehind(in repoRoot: String) -> (ahead: Int, behind: Int)? {
    let quoted = shellQuote(repoRoot)
    let command = "git -C \(quoted) rev-list --left-right --count HEAD...origin/main"
    let result = runShellCommand(command)
    guard result.status == 0 else {
        return nil
    }
    let line = result.output
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .last ?? result.output
    let tokens = line
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    guard tokens.count >= 2,
          let ahead = Int(tokens[0]),
          let behind = Int(tokens[1])
    else {
        return nil
    }
    return (ahead: ahead, behind: behind)
}

private func readBatteryStatus() -> BatteryStatus {
    let result = runShellCommand("pmset -g batt")
    let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.status == 0 else {
        return BatteryStatus(percent: nil, isCharging: false, raw: output)
    }

    let percentMatch = output.range(of: #"(\d+)%"#, options: .regularExpression)
    let percent = percentMatch.flatMap { Int(output[$0].dropLast()) }
    let isCharging = output.localizedCaseInsensitiveContains("AC Power")
        || output.localizedCaseInsensitiveContains("charging")
        || output.localizedCaseInsensitiveContains("charged")
    return BatteryStatus(percent: percent, isCharging: isCharging, raw: output)
}

private func discoverModelCatalog(in repoRoot: String) -> ModelCatalog {
    let fileManager = FileManager.default
    let rootURL = URL(fileURLWithPath: repoRoot, isDirectory: true)

    let modelExtensions: Set<String> = [
        "bin",
        "ckpt",
        "gguf",
        "mlmodel",
        "mlpackage",
        "npz",
        "onnx",
        "pt",
        "pth",
        "safetensors",
        "tflite",
    ]

    let skipDirectories: Set<String> = [
        ".build",
        ".git",
        ".private",
        "build",
        "dist",
        "node_modules",
        "venv",
        ".venv",
    ]

    var artifacts: [ModelArtifact] = []

    guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return ModelCatalog(artifacts: [])
    }

    while let url = enumerator.nextObject() as? URL {
        let relativePath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        let components = Set(relativePath.split(separator: "/").map(String.init))

        if !components.isDisjoint(with: skipDirectories) {
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
                enumerator.skipDescendants()
            }
            continue
        }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory == true
        let isRegularFile = values?.isRegularFile == true

        if isDirectory, url.pathExtension.lowercased() == "mlpackage" {
            artifacts.append(
                ModelArtifact(
                    relativePath: relativePath,
                    fileExtension: "mlpackage",
                    sizeBytes: 0,
                    modifiedAt: values?.contentModificationDate
                )
            )
            enumerator.skipDescendants()
            continue
        }

        guard isRegularFile else {
            continue
        }

        let ext = url.pathExtension.lowercased()
        guard modelExtensions.contains(ext) else {
            continue
        }

        let size = UInt64(max(0, values?.fileSize ?? 0))
        artifacts.append(
            ModelArtifact(
                relativePath: relativePath,
                fileExtension: ext,
                sizeBytes: size,
                modifiedAt: values?.contentModificationDate
            )
        )
    }

    artifacts.sort { $0.relativePath < $1.relativePath }
    return ModelCatalog(artifacts: artifacts)
}

private struct ModelHealthSummary {
    var new24h: Int
    var new7d: Int
    var missingTokenizer: Int
    var missingConfig: Int
    var sizeBucketCounts: [String: Int]
}

private func modelHealthSummary(catalog: ModelCatalog, repoRoot: String) -> ModelHealthSummary {
    let fileManager = FileManager.default
    let now = Date()
    let oneDayAgo = now.addingTimeInterval(-24 * 3600)
    let oneWeekAgo = now.addingTimeInterval(-7 * 24 * 3600)

    var new24h = 0
    var new7d = 0
    var missingTokenizer = 0
    var missingConfig = 0
    var buckets: [String: Int] = [:]

    func sizeBucket(for size: UInt64) -> String {
        switch size {
        case 0..<10_000_000:
            return "<10MB"
        case 10_000_000..<100_000_000:
            return "10-100MB"
        case 100_000_000..<1_000_000_000:
            return "100MB-1GB"
        default:
            return ">=1GB"
        }
    }

    for artifact in catalog.artifacts {
        if let modifiedAt = artifact.modifiedAt {
            if modifiedAt >= oneDayAgo {
                new24h += 1
            }
            if modifiedAt >= oneWeekAgo {
                new7d += 1
            }
        }

        buckets[sizeBucket(for: artifact.sizeBytes), default: 0] += 1

        let needsTokenizer = ["gguf", "safetensors", "pt", "pth", "bin", "onnx"].contains(artifact.fileExtension)
        let needsConfig = ["safetensors", "pt", "pth", "onnx"].contains(artifact.fileExtension)
        if !(needsTokenizer || needsConfig) {
            continue
        }

        let parent = URL(fileURLWithPath: repoRoot).appendingPathComponent(artifact.relativePath).deletingLastPathComponent().path
        let tokenizerCandidates = [
            "\(parent)/tokenizer.json",
            "\(parent)/tokenizer.model",
            "\(parent)/tokenizer.bin",
            "\(parent)/vocab.json",
        ]
        let configCandidates = [
            "\(parent)/config.json",
            "\(parent)/generation_config.json",
        ]

        if needsTokenizer && !tokenizerCandidates.contains(where: { fileManager.fileExists(atPath: $0) }) {
            missingTokenizer += 1
        }
        if needsConfig && !configCandidates.contains(where: { fileManager.fileExists(atPath: $0) }) {
            missingConfig += 1
        }
    }

    return ModelHealthSummary(
        new24h: new24h,
        new7d: new7d,
        missingTokenizer: missingTokenizer,
        missingConfig: missingConfig,
        sizeBucketCounts: buckets
    )
}

private struct InferenceRuntimeCandidate {
    var label: String
    var commandTemplate: String
}

private func discoverInferenceRuntimeCandidates(in repoRoot: String) -> [InferenceRuntimeCandidate] {
    let fileManager = FileManager.default
    let rootURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
    let trainingURL = rootURL.appendingPathComponent("training", isDirectory: true)
    var candidates: [InferenceRuntimeCandidate] = []
    var seenTemplates: Set<String> = []

    func appendCandidate(label: String, template: String) {
        guard !template.isEmpty, !seenTemplates.contains(template) else {
            return
        }
        seenTemplates.insert(template)
        candidates.append(InferenceRuntimeCandidate(label: label, commandTemplate: template))
    }

    let knownPaths = [
        "training/inference/chat.py",
        "training/inference.py",
        "training/chat.py",
        "inference/chat.py",
        "inference/run_chat.py",
    ]
    for path in knownPaths where fileManager.fileExists(atPath: rootURL.appendingPathComponent(path).path) {
        appendCandidate(
            label: path,
            template: "uv run python \(path) --model {model} --prompt {prompt} --stream"
        )
    }

    guard fileManager.fileExists(atPath: trainingURL.path),
          let enumerator = fileManager.enumerator(
            at: trainingURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          )
    else {
        return candidates
    }

    let triggerTokens = ["infer", "inference", "chat", "generate", "qwen", "llm"]

    while let fileURL = enumerator.nextObject() as? URL {
        guard ["py", "sh"].contains(fileURL.pathExtension.lowercased()) else {
            continue
        }
        let relPath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        let lowerName = fileURL.lastPathComponent.lowercased()
        guard triggerTokens.contains(where: { lowerName.contains($0) }) else {
            continue
        }

        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let lowerText = text.lowercased()
        let hasPrompt = lowerText.contains("--prompt") || lowerText.contains("prompt")
        guard hasPrompt else {
            continue
        }

        let hasModel = lowerText.contains("--model")
        let hasRepo = lowerText.contains("--repo")
        let hasStream = lowerText.contains("--stream")
        let hasPromptFlag = lowerText.contains("--prompt")

        var command: String
        if fileURL.pathExtension.lowercased() == "py" {
            command = "uv run python \(relPath)"
        } else {
            command = "bash \(relPath)"
        }

        if hasModel {
            command += " --model {model}"
        }
        if hasRepo {
            command += " --repo {repo}"
        }
        if hasPromptFlag {
            command += " --prompt {prompt}"
        } else {
            command += " {prompt}"
        }
        if hasStream {
            command += " --stream"
        }

        appendCandidate(label: relPath, template: command)
    }

    return candidates.sorted { lhs, rhs in
        lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.includesCount = true
    return formatter.string(fromByteCount: Int64(bytes))
}

private func truncate(_ text: String, maxLength: Int) -> String {
    guard text.count > maxLength else {
        return text
    }
    let end = text.index(text.startIndex, offsetBy: max(0, maxLength - 1))
    return String(text[..<end]) + "…"
}

private func abbreviatedPath(_ path: String, maxLength: Int = 48) -> String {
    let expanded = NSString(string: path).abbreviatingWithTildeInPath
    guard expanded.count > maxLength else {
        return expanded
    }

    let components = expanded.split(separator: "/").map(String.init)
    guard components.count >= 3 else {
        return truncate(expanded, maxLength: maxLength)
    }

    let tail = components.suffix(3).joined(separator: "/")
    let prefix = expanded.hasPrefix("/") ? "/" : ""
    let compact = "\(prefix)…/\(tail)"
    return truncate(compact, maxLength: maxLength)
}

private func formatDuration(_ seconds: Double) -> String {
    let duration = max(0, Int(seconds.rounded()))
    let minutes = duration / 60
    let remainingSeconds = duration % 60
    return String(format: "%dm %02ds", minutes, remainingSeconds)
}

private func formatSigned(_ value: Double, suffix: String = "") -> String {
    let sign = value >= 0 ? "+" : ""
    return String(format: "%@%.2f%@", sign, value, suffix)
}

private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
        return "nominal"
    case .fair:
        return "fair"
    case .serious:
        return "serious"
    case .critical:
        return "critical"
    @unknown default:
        return "unknown"
    }
}

private struct ResearchSummarySnapshot {
    var aneTFLOPS: Double?
    var aneUtilization: Double?
    var avgStepMS: Double?
}

private func parseResearchSummary(in repoRoot: String) -> ResearchSummarySnapshot? {
    let csvPath = "\(repoRoot)/training/research/results/data/qos_summary.csv"
    guard let csvText = try? String(contentsOfFile: csvPath, encoding: .utf8) else {
        let probePath = "\(repoRoot)/training/research/results/data/probe_summary.json"
        guard let probeData = try? Data(contentsOf: URL(fileURLWithPath: probePath)),
              let json = try? JSONSerialization.jsonObject(with: probeData) as? [String: Any],
              let kernelMFLOPS = json["kernel_mflops"] as? Double
        else {
            return nil
        }
        let tflops = kernelMFLOPS / 1000.0
        let peakTFLOPS = Double(ProcessInfo.processInfo.environment["ANE_PEAK_TFLOPS"] ?? "") ?? 15.8
        let util = peakTFLOPS > 0 ? (tflops / peakTFLOPS) * 100.0 : nil
        return ResearchSummarySnapshot(aneTFLOPS: tflops, aneUtilization: util, avgStepMS: nil)
    }

    let lines = csvText
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .filter { !$0.isEmpty }
    guard lines.count >= 2 else {
        return nil
    }

    let headers = lines[0].split(separator: ",").map(String.init)
    guard let evalIndex = headers.firstIndex(of: "eval_avg_ms_mean"),
          let throughputIndex = headers.firstIndex(of: "throughput_gflops_mean")
    else {
        return nil
    }

    var bestEvalMS: Double?
    var bestThroughputGFLOPS: Double?

    for line in lines.dropFirst() {
        let columns = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard columns.count > max(evalIndex, throughputIndex),
              let evalMS = Double(columns[evalIndex]),
              let throughput = Double(columns[throughputIndex])
        else {
            continue
        }

        if bestEvalMS == nil || evalMS < (bestEvalMS ?? .greatestFiniteMagnitude) {
            bestEvalMS = evalMS
            bestThroughputGFLOPS = throughput
        }
    }

    guard let throughput = bestThroughputGFLOPS else {
        return nil
    }

    let aneTFLOPS = throughput / 1000.0
    let peakTFLOPS = Double(ProcessInfo.processInfo.environment["ANE_PEAK_TFLOPS"] ?? "") ?? 15.8
    let aneUtil = peakTFLOPS > 0 ? (aneTFLOPS / peakTFLOPS) * 100.0 : nil
    return ResearchSummarySnapshot(
        aneTFLOPS: aneTFLOPS,
        aneUtilization: aneUtil,
        avgStepMS: bestEvalMS
    )
}

private func configuredPeakTFLOPS() -> Double {
    Double(ProcessInfo.processInfo.environment["ANE_PEAK_TFLOPS"] ?? "") ?? 15.8
}

private func parseBestTFLOPSFromTable(_ text: String) -> Double? {
    var best: Double?
    for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("FAIL(") else {
            continue
        }
        let matches = line.matches(of: /([0-9]+(?:\.[0-9]+)?)\s*(?:%|ms)?/)
        let numbers = matches.compactMap { Double($0.1) }
        guard numbers.count >= 2 else {
            continue
        }
        let candidate = numbers[numbers.count - 2]
        if candidate > 0, (best == nil || candidate > (best ?? 0)) {
            best = candidate
        }
    }
    return best
}

private func parseQosSweepSummary(_ text: String) -> ResearchSummarySnapshot? {
    guard let kernelMatch = text.firstMatch(of: /Kernel:\s+.*\(([0-9]+(?:\.[0-9]+)?)\s+MFLOPS\)/),
          let kernelMFLOPS = Double(kernelMatch.1)
    else {
        return nil
    }

    var bestEvalMS: Double?
    for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasSuffix("OK") else {
            continue
        }
        let matches = line.matches(of: /([0-9]+(?:\.[0-9]+)?)ms/)
        let values = matches.compactMap { Double($0.1) }
        guard values.count >= 4 else {
            continue
        }
        let evalAverage = values[3]
        if bestEvalMS == nil || evalAverage < (bestEvalMS ?? .greatestFiniteMagnitude) {
            bestEvalMS = evalAverage
        }
    }

    guard let bestEvalMS else {
        return nil
    }
    let throughputGFLOPS = kernelMFLOPS / bestEvalMS
    let aneTFLOPS = throughputGFLOPS / 1000.0
    let peak = configuredPeakTFLOPS()
    let utilization = peak > 0 ? (aneTFLOPS / peak) * 100.0 : nil
    return ResearchSummarySnapshot(
        aneTFLOPS: aneTFLOPS,
        aneUtilization: utilization,
        avgStepMS: bestEvalMS
    )
}

private func isLiveTelemetrySource(_ source: String?) -> Bool {
    switch source {
    case "live JSON stream", "dashboard live stream", "powermetrics live":
        return true
    default:
        return false
    }
}

@MainActor
private final class ExperimentActionButton: NSButton {
    var experimentID: String = ""
}

@MainActor
private final class TelemetryWindowController: NSWindowController {
    private let metricsView = LiveMetricsMenuView(frame: NSRect(x: 0, y: 0, width: 860, height: 520))
    private let headlineLabel = NSTextField(labelWithString: "ANEBar Telemetry")
    private let detailLabel = NSTextField(labelWithString: "Waiting for metrics…")

    override init(window: NSWindow?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ANEBar Telemetry"
        window.minSize = NSSize(width: 720, height: 520)
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func push(sample: LiveMetricsSample) {
        metricsView.push(sample)
    }

    func updateContext(repoProfile: RepoProfile, repoRoot: String, currentRunTitle: String?, telemetrySource: String?) {
        headlineLabel.stringValue = currentRunTitle.map { "ANEBar Telemetry | \($0)" } ?? "ANEBar Telemetry"
        detailLabel.stringValue = "Profile \(repoProfile.label) | \(telemetrySource ?? "idle") | \(abbreviatedPath(repoRoot, maxLength: 72))"
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        headlineLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor

        metricsView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headlineLabel, detailLabel, metricsView])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            metricsView.heightAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])
    }
}

@MainActor
private final class ExperimentConsoleWindowController: NSWindowController {
    private let summaryLabel = NSTextField(labelWithString: "ANE experiments")
    private let detailLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let searchField = NSSearchField(frame: .zero)
    private let groupPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private var allExperiments: [ExperimentDefinition] = []
    private var experimentsByID: [String: ExperimentDefinition] = [:]
    private var repoRoot: String = ""
    private var runButtons: [ExperimentActionButton] = []
    private var queueButtons: [ExperimentActionButton] = []
    private var isBusy: Bool = false

    var onRunExperiment: ((ExperimentDefinition) -> Void)?
    var onQueueExperiment: ((ExperimentDefinition) -> Void)?
    var onCopyExperimentCommand: ((ExperimentDefinition) -> String?)?
    var onRefresh: (() -> Void)?

    override init(window: NSWindow?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ANEBar Experiment Console"
        window.minSize = NSSize(width: 640, height: 520)
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(profile: RepoProfile, repoRoot: String, experiments: [ExperimentDefinition]) {
        self.repoRoot = repoRoot
        allExperiments = experiments
        experimentsByID = Dictionary(uniqueKeysWithValues: experiments.map { ($0.id, $0) })
        let runnableCount = experiments.filter(\.isRunnable).count
        summaryLabel.stringValue = "\(profile.label) | \(runnableCount) runnable / \(experiments.count) catalogued"
        detailLabel.stringValue = profile.detail
        rebuildContent(experiments: filteredExperiments())
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        for button in runButtons {
            let runnable: Bool
            if let experiment = experimentsByID[button.experimentID] {
                runnable = experiment.isRunnable && missingPrerequisites(for: experiment, repoRoot: repoRoot).isEmpty
            } else {
                runnable = false
            }
            button.isEnabled = !busy && runnable
        }
        for button in queueButtons {
            let runnable: Bool
            if let experiment = experimentsByID[button.experimentID] {
                runnable = experiment.isRunnable && missingPrerequisites(for: experiment, repoRoot: repoRoot).isEmpty
            } else {
                runnable = false
            }
            button.isEnabled = !busy && runnable
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        summaryLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2

        searchField.placeholderString = "Search experiments"
        searchField.target = self
        searchField.action = #selector(filterChanged)

        groupPopup.addItems(withTitles: ["All"] + ExperimentGroup.allCases.map(\.rawValue))
        groupPopup.target = self
        groupPopup.action = #selector(filterChanged)

        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)

        let headerStack = NSStackView(views: [summaryLabel, NSView(), refreshButton])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 10

        let filterStack = NSStackView(views: [searchField, groupPopup])
        filterStack.orientation = .horizontal
        filterStack.alignment = .centerY
        filterStack.spacing = 10
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentStack.orientation = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        let root = NSStackView(views: [headerStack, detailLabel, filterStack, scrollView])
        root.orientation = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    private func rebuildContent(experiments: [ExperimentDefinition]) {
        runButtons = []
        queueButtons = []
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if experiments.isEmpty {
            let empty = NSTextField(labelWithString: "No experiments match the current filters.")
            empty.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(empty)
            return
        }

        let grouped = Dictionary(grouping: experiments) { $0.group }
        for group in ExperimentGroup.allCases {
            guard let groupExperiments = grouped[group], !groupExperiments.isEmpty else {
                continue
            }

            let header = NSTextField(labelWithString: group.rawValue)
            header.font = .systemFont(ofSize: 14, weight: .semibold)
            header.textColor = .labelColor
            contentStack.addArrangedSubview(header)

            for experiment in groupExperiments {
                contentStack.addArrangedSubview(makeCard(for: experiment))
            }
        }
        setBusy(isBusy)
    }

    private func makeCard(for experiment: ExperimentDefinition) -> NSView {
        let missing = missingPrerequisites(for: experiment, repoRoot: repoRoot)
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42).cgColor

        let titleLabel = NSTextField(labelWithString: experiment.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let summaryLabel = NSTextField(wrappingLabelWithString: experiment.summary)
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        let metaParts = [experiment.metadataLine] + (missing.isEmpty ? [] : ["missing: " + missing.joined(separator: ", ")])
        let metaLabel = NSTextField(labelWithString: metaParts.joined(separator: " | "))
        metaLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = .tertiaryLabelColor

        let runTitle = !experiment.isRunnable ? "Catalogued" : (missing.isEmpty ? "Run" : "Blocked")
        let runButton = ExperimentActionButton(title: runTitle, target: self, action: #selector(runPressed(_:)))
        runButton.experimentID = experiment.id
        runButton.isEnabled = experiment.isRunnable && missing.isEmpty
        runButtons.append(runButton)

        let copyButton = ExperimentActionButton(title: experiment.isRunnable ? "Copy Command" : "Copy Source Path", target: self, action: #selector(copyPressed(_:)))
        copyButton.experimentID = experiment.id

        let queueButton = ExperimentActionButton(title: "Queue", target: self, action: #selector(queuePressed(_:)))
        queueButton.experimentID = experiment.id
        queueButton.isEnabled = experiment.isRunnable && missing.isEmpty
        queueButtons.append(queueButton)

        let buttonStack = NSStackView(views: [runButton, queueButton, copyButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let root = NSStackView(views: [titleLabel, summaryLabel, metaLabel, buttonStack])
        root.orientation = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])

        return card
    }

    @objc private func refreshPressed() {
        onRefresh?()
    }

    @objc private func filterChanged() {
        rebuildContent(experiments: filteredExperiments())
    }

    @objc private func runPressed(_ sender: ExperimentActionButton) {
        guard let experiment = experimentsByID[sender.experimentID] else {
            return
        }
        onRunExperiment?(experiment)
    }

    @objc private func queuePressed(_ sender: ExperimentActionButton) {
        guard let experiment = experimentsByID[sender.experimentID] else {
            return
        }
        onQueueExperiment?(experiment)
    }

    @objc private func copyPressed(_ sender: ExperimentActionButton) {
        guard let experiment = experimentsByID[sender.experimentID] else {
            return
        }
        let text = onCopyExperimentCommand?(experiment) ?? experiment.sourcePath ?? experiment.id
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        detailLabel.stringValue = "Copied: \(text)"
    }

    private func filteredExperiments() -> [ExperimentDefinition] {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selectedGroup = groupPopup.titleOfSelectedItem ?? "All"

        return allExperiments.filter { experiment in
            let matchesGroup = selectedGroup == "All" || experiment.group.rawValue == selectedGroup
            let haystack = [
                experiment.id,
                experiment.title,
                experiment.summary,
                experiment.sourcePath ?? "",
                experiment.telemetry,
            ]
            .joined(separator: " ")
            .lowercased()
            let matchesQuery = query.isEmpty || haystack.contains(query)
            return matchesGroup && matchesQuery
        }
    }
}

@MainActor
private final class HistoryWindowController: NSWindowController {
    private let summaryLabel = NSTextField(labelWithString: "ANEBar History")
    private let detailLabel = NSTextField(labelWithString: "Recent runs and side-by-side comparison.")
    private let primaryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let comparePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rerunButton = NSButton(title: "Re-run", target: nil, action: nil)
    private let copyCommandButton = NSButton(title: "Copy Command", target: nil, action: nil)
    private let exportReproButton = NSButton(title: "Export Repro", target: nil, action: nil)
    private let openSummaryButton = NSButton(title: "Open Summary", target: nil, action: nil)
    private let openJSONButton = NSButton(title: "Open JSON", target: nil, action: nil)
    private let copySocialButton = NSButton(title: "Copy Social Snippet", target: nil, action: nil)
    private let outputTextView = NSTextView(frame: .zero)

    private var records: [RunRecord] = []
    private var primaryIDs: [String] = []
    private var compareIDs: [String?] = []
    private var currentRepoRoot: String = ""
    private var isBusy: Bool = false

    var onRerun: ((RunRecord) -> Void)?
    var onCopyCommand: ((RunRecord) -> String?)?
    var onExportRepro: (() -> Void)?
    var onOpenSummary: (() -> Void)?
    var onOpenHistoryJSON: (() -> Void)?
    var onCopySocialSnippet: ((RunRecord, RunRecord?) -> String?)?

    override init(window: NSWindow?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ANEBar History"
        window.minSize = NSSize(width: 760, height: 560)
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(records: [RunRecord], repoRoot: String) {
        self.records = records.sorted { $0.endedAt > $1.endedAt }
        currentRepoRoot = repoRoot
        summaryLabel.stringValue = "ANEBar History | \(self.records.count) runs"
        detailLabel.stringValue = abbreviatedPath(repoRoot, maxLength: 84)
        rebuildSelectors()
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        rerunButton.isEnabled = !busy && selectedPrimaryRecord() != nil
        copyCommandButton.isEnabled = selectedPrimaryRecord() != nil
        exportReproButton.isEnabled = !records.isEmpty
        openSummaryButton.isEnabled = !records.isEmpty
        openJSONButton.isEnabled = !records.isEmpty
        copySocialButton.isEnabled = selectedPrimaryRecord() != nil
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        summaryLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor

        primaryPopup.target = self
        primaryPopup.action = #selector(selectionChanged)
        comparePopup.target = self
        comparePopup.action = #selector(selectionChanged)

        rerunButton.target = self
        rerunButton.action = #selector(rerunPressed)
        copyCommandButton.target = self
        copyCommandButton.action = #selector(copyCommandPressed)
        exportReproButton.target = self
        exportReproButton.action = #selector(exportReproPressed)
        openSummaryButton.target = self
        openSummaryButton.action = #selector(openSummaryPressed)
        openJSONButton.target = self
        openJSONButton.action = #selector(openJSONPressed)
        copySocialButton.target = self
        copySocialButton.action = #selector(copySocialPressed)

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.backgroundColor = .clear
        outputTextView.textColor = .labelColor

        let outputScrollView = NSScrollView()
        outputScrollView.drawsBackground = false
        outputScrollView.hasVerticalScroller = true
        outputScrollView.borderType = .noBorder
        outputScrollView.documentView = outputTextView
        outputScrollView.translatesAutoresizingMaskIntoConstraints = false

        let runRow = NSStackView(views: [
            NSTextField(labelWithString: "Run"),
            primaryPopup,
            NSTextField(labelWithString: "Compare"),
            comparePopup,
        ])
        runRow.orientation = .horizontal
        runRow.alignment = .centerY
        runRow.spacing = 10
        primaryPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        comparePopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [
            rerunButton,
            copyCommandButton,
            exportReproButton,
            openSummaryButton,
            openJSONButton,
            copySocialButton,
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let root = NSStackView(views: [summaryLabel, detailLabel, runRow, actions, outputScrollView])
        root.orientation = .vertical
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            outputScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
    }

    private func rebuildSelectors() {
        let previousPrimary = selectedPrimaryRecord()?.id
        let previousCompare = selectedCompareRecord()?.id

        primaryPopup.removeAllItems()
        comparePopup.removeAllItems()
        primaryIDs = []
        compareIDs = []

        if records.isEmpty {
            primaryPopup.addItem(withTitle: "No runs yet")
            comparePopup.addItem(withTitle: "No compare")
            outputTextView.string = "Run an experiment to populate history."
            setBusy(isBusy)
            return
        }

        for record in records {
            primaryPopup.addItem(withTitle: label(for: record))
            primaryIDs.append(record.id)
        }

        comparePopup.addItem(withTitle: "No compare")
        compareIDs.append(nil)
        for record in records {
            comparePopup.addItem(withTitle: label(for: record))
            compareIDs.append(record.id)
        }

        if let previousPrimary, let index = primaryIDs.firstIndex(of: previousPrimary) {
            primaryPopup.selectItem(at: index)
        } else {
            primaryPopup.selectItem(at: 0)
        }

        if let previousCompare, let index = compareIDs.firstIndex(of: previousCompare) {
            comparePopup.selectItem(at: index)
        } else {
            comparePopup.selectItem(at: min(2, comparePopup.numberOfItems - 1))
        }

        if selectedCompareRecord()?.id == selectedPrimaryRecord()?.id {
            comparePopup.selectItem(at: 0)
        }

        refreshDetail()
    }

    private func selectedPrimaryRecord() -> RunRecord? {
        let index = primaryPopup.indexOfSelectedItem
        guard index >= 0, index < primaryIDs.count else {
            return nil
        }
        return records.first { $0.id == primaryIDs[index] }
    }

    private func selectedCompareRecord() -> RunRecord? {
        let index = comparePopup.indexOfSelectedItem
        guard index >= 0, index < compareIDs.count, let id = compareIDs[index] else {
            return nil
        }
        return records.first { $0.id == id }
    }

    private func label(for record: RunRecord) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: record.endedAt, relativeTo: Date())
        let outcome = record.exitCode == 0 ? "ok" : "fail \(record.exitCode)"
        return "\(record.title ?? record.mode) | \(outcome) | \(relative)"
    }

    private func refreshDetail() {
        guard let primary = selectedPrimaryRecord() else {
            outputTextView.string = "Run an experiment to populate history."
            setBusy(isBusy)
            return
        }

        let compare = selectedCompareRecord()?.id == primary.id ? nil : selectedCompareRecord()
        outputTextView.string = detailString(for: primary, comparedTo: compare)
        setBusy(isBusy)
    }

    private func detailString(for primary: RunRecord, comparedTo compare: RunRecord?) -> String {
        var lines: [String] = []
        lines.append("# Selected Run")
        lines.append("")
        lines.append("- Title: \(primary.title ?? primary.mode)")
        lines.append("- Ended: \(ISO8601DateFormatter().string(from: primary.endedAt))")
        lines.append("- Duration: \(formatDuration(primary.durationSeconds))")
        lines.append("- Exit: \(primary.exitCode)")
        lines.append("- Telemetry: \(primary.telemetrySource ?? "n/a")")
        lines.append("- Group: \(primary.group ?? "n/a")")
        lines.append("- Repo head: \(primary.repoHead ?? "unknown")")
        lines.append("- Repo root: \(primary.repoRoot)")
        lines.append("- Working dir: \(primary.workingDirectory ?? primary.repoRoot)")
        lines.append("- Command: \(primary.command)")
        lines.append("")
        lines.append("# Metrics")
        lines.append(metricLine(prefix: "ANE TFLOPS", value: primary.aneTFLOPS, format: "%.2f"))
        lines.append(metricLine(prefix: "ANE util", value: primary.aneUtilization, format: "%.2f%%"))
        lines.append(metricLine(prefix: "Avg train", value: primary.avgTrainMS, format: "%.2f ms"))
        lines.append(metricLine(prefix: "Total TFLOPS", value: primary.totalTFLOPS, format: "%.2f"))

        if let compare {
            lines.append("")
            lines.append("# Compare")
            lines.append("")
            lines.append("- Against: \(compare.title ?? compare.mode)")
            let deltas = comparisonLines(current: primary, previous: compare)
            if deltas.isEmpty {
                lines.append("- Deltas: n/a")
            } else {
                for delta in deltas {
                    lines.append("- \(delta)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private func metricLine(prefix: String, value: Double?, format: String) -> String {
        guard let value else {
            return "- \(prefix): n/a"
        }
        return "- \(prefix): " + String(format: format, value)
    }

    private func comparisonLines(current: RunRecord, previous: RunRecord) -> [String] {
        var lines: [String] = []
        if let currentValue = current.aneTFLOPS, let previousValue = previous.aneTFLOPS {
            lines.append("ANE TFLOPS " + formatSigned(currentValue - previousValue, suffix: ""))
        }
        if let currentValue = current.aneUtilization, let previousValue = previous.aneUtilization {
            lines.append("ANE util " + formatSigned(currentValue - previousValue, suffix: "%"))
        }
        if let currentValue = current.avgTrainMS, let previousValue = previous.avgTrainMS {
            lines.append("Avg train " + formatSigned(currentValue - previousValue, suffix: "ms"))
        }
        lines.append("Duration " + formatSigned(current.durationSeconds - previous.durationSeconds, suffix: "s"))
        return lines
    }

    @objc private func selectionChanged() {
        refreshDetail()
    }

    @objc private func rerunPressed() {
        guard let primary = selectedPrimaryRecord() else {
            return
        }
        onRerun?(primary)
    }

    @objc private func copyCommandPressed() {
        guard let primary = selectedPrimaryRecord() else {
            return
        }
        let text = onCopyCommand?(primary) ?? primary.command
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        detailLabel.stringValue = "Copied command for \(primary.title ?? primary.mode)"
    }

    @objc private func exportReproPressed() {
        onExportRepro?()
    }

    @objc private func openSummaryPressed() {
        onOpenSummary?()
    }

    @objc private func openJSONPressed() {
        onOpenHistoryJSON?()
    }

    @objc private func copySocialPressed() {
        guard let primary = selectedPrimaryRecord() else {
            return
        }
        let compare = selectedCompareRecord()?.id == primary.id ? nil : selectedCompareRecord()
        let text = onCopySocialSnippet?(primary, compare) ?? socialSnippet(for: primary, comparedTo: compare)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        detailLabel.stringValue = "Copied social snippet for \(primary.title ?? primary.mode)"
    }

    private func socialSnippet(for primary: RunRecord, comparedTo compare: RunRecord?) -> String {
        var parts: [String] = []
        parts.append("\(primary.title ?? primary.mode) on Apple Silicon")
        if let tflops = primary.aneTFLOPS {
            parts.append(String(format: "ANE %.2f TFLOPS", tflops))
        }
        if let util = primary.aneUtilization {
            parts.append(String(format: "util %.1f%%", util))
        }
        if let avg = primary.avgTrainMS {
            parts.append(String(format: "avg %.1f ms", avg))
        }
        if let compare,
           let current = primary.aneTFLOPS,
           let previous = compare.aneTFLOPS
        {
            parts.append("vs prev " + formatSigned(current - previous, suffix: " TFLOPS"))
        }
        return parts.joined(separator: " | ")
    }
}

@MainActor
private final class ChatWindowController: NSWindowController {
    private enum DefaultsKey {
        static let chatModel = "anebar_chat_model"
        static let chatRuntimeTemplate = "anebar_chat_runtime_template"
    }

    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let runtimeField = NSTextField()
    private let promptField = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh Models", target: nil, action: nil)
    private let detectRuntimeButton = NSButton(title: "Detect ANE Runtime", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "ANE chat ready")
    private let outputTextView = NSTextView(frame: .zero)

    private var chatProcess: Process?
    private var repoRoot: String = ""
    private var fallbackModels: [String] = []
    private var runtimeCandidates: [InferenceRuntimeCandidate] = []
    private var streamStartedAt: Date?
    private var streamTokenApproxCount: Int = 0

    override init(window: NSWindow?) {
        let initialRect = NSRect(x: 0, y: 0, width: 680, height: 520)
        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ANEbar ANE Chat"
        window.minSize = NSSize(width: 560, height: 420)
        super.init(window: window)
        setupUI()
        bootstrapRuntimeTemplateIfNeeded()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setFallbackModels(_ models: [String]) {
        fallbackModels = Array(Set(models)).sorted()
        reloadModels(preserveSelection: true)
    }

    func setRepoRoot(_ path: String) {
        repoRoot = path
        refreshRuntimeCandidates()
        reloadModels(preserveSelection: true)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let runtimeLabel = NSTextField(labelWithString: "ANE Runtime")
        runtimeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        runtimeField.placeholderString = "uv run python training/inference/chat.py --model {model} --prompt {prompt} --stream"
        runtimeField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        runtimeField.target = self
        runtimeField.action = #selector(saveRuntimeTemplate)

        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        modelPopup.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        promptField.placeholderString = "Prompt (press Enter or click Send)"
        promptField.font = .systemFont(ofSize: 13)
        promptField.target = self
        promptField.action = #selector(sendPrompt)

        sendButton.target = self
        sendButton.action = #selector(sendPrompt)
        sendButton.keyEquivalent = "\r"

        stopButton.target = self
        stopButton.action = #selector(stopChat)
        stopButton.isEnabled = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshModels)

        detectRuntimeButton.target = self
        detectRuntimeButton.action = #selector(detectRuntimeNow)

        clearButton.target = self
        clearButton.action = #selector(clearOutput)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.isRichText = false
        outputTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.string = "ANEbar ANE chat. Configure ANE runtime template and start chatting.\n"
        outputTextView.textColor = .labelColor
        outputTextView.backgroundColor = .textBackgroundColor

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.documentView = outputTextView

        let runtimeStack = NSStackView(views: [runtimeLabel, runtimeField, detectRuntimeButton])
        runtimeStack.orientation = .horizontal
        runtimeStack.spacing = 10
        runtimeStack.alignment = .centerY
        runtimeStack.distribution = .gravityAreas
        runtimeField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        runtimeField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controlsStack = NSStackView(views: [modelLabel, modelPopup, refreshButton, stopButton, clearButton])
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 10
        controlsStack.alignment = .centerY
        controlsStack.distribution = .gravityAreas
        modelPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let promptStack = NSStackView(views: [promptField, sendButton])
        promptStack.orientation = .horizontal
        promptStack.spacing = 10
        promptStack.alignment = .centerY

        let root = NSStackView(views: [runtimeStack, controlsStack, promptStack, scrollView, statusLabel])
        root.orientation = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(root)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    private func bootstrapRuntimeTemplateIfNeeded() {
        if let saved = UserDefaults.standard.string(forKey: DefaultsKey.chatRuntimeTemplate),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            runtimeField.stringValue = saved
            return
        }
        runtimeField.stringValue = "uv run python training/inference/chat.py --model {model} --prompt {prompt} --stream"
    }

    private func discoverRepoModels() -> [String] {
        guard !repoRoot.isEmpty else {
            return []
        }

        let catalog = discoverModelCatalog(in: repoRoot)
        var names = catalog.artifacts.map {
            URL(fileURLWithPath: $0.relativePath).deletingPathExtension().lastPathComponent
        }

        // Keep model list readable and useful for small LLM demos.
        names = names
            .filter { !$0.isEmpty && $0.count >= 3 }
            .map { $0.replacingOccurrences(of: "_", with: "-") }
        return Array(Set(names)).sorted()
    }

    @objc private func refreshModels() {
        reloadModels(preserveSelection: true)
    }

    @objc private func saveRuntimeTemplate() {
        let template = runtimeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(template, forKey: DefaultsKey.chatRuntimeTemplate)
    }

    @objc private func detectRuntimeNow() {
        refreshRuntimeCandidates()
    }

    private func refreshRuntimeCandidates() {
        runtimeCandidates = discoverInferenceRuntimeCandidates(in: repoRoot)
        if runtimeCandidates.isEmpty {
            statusLabel.stringValue = "No ANE inference script detected. Set runtime template manually."
            return
        }

        let picked = runtimeCandidates[0]
        runtimeField.stringValue = picked.commandTemplate
        UserDefaults.standard.set(picked.commandTemplate, forKey: DefaultsKey.chatRuntimeTemplate)
        statusLabel.stringValue = "Detected runtime: \(picked.label)"
    }

    private func reloadModels(preserveSelection: Bool) {
        let previous = preserveSelection ? modelPopup.titleOfSelectedItem : nil
        let discovered = discoverRepoModels()
        let defaults = ["Qwen3.5-0.8B", "TinyLlama-1.1B-Chat-v1.0", "Qwen2.5-0.5B-Instruct"]
        let merged = Array(Set(defaults + fallbackModels + discovered)).sorted()

        modelPopup.removeAllItems()
        if merged.isEmpty {
            statusLabel.stringValue = "No local model artifacts found in repo."
            return
        }
        modelPopup.addItems(withTitles: merged)

        if let previous, merged.contains(previous) {
            modelPopup.selectItem(withTitle: previous)
        } else if let saved = UserDefaults.standard.string(forKey: DefaultsKey.chatModel), merged.contains(saved) {
            modelPopup.selectItem(withTitle: saved)
        } else if let first = merged.first {
            modelPopup.selectItem(withTitle: first)
        }

        if discovered.isEmpty, !repoRoot.isEmpty {
            statusLabel.stringValue = "Using fallback models. Add model artifacts to \(abbreviatedPath(repoRoot))."
        } else {
            statusLabel.stringValue = "Ready. Streaming from ANE runtime."
        }
    }

    @objc private func clearOutput() {
        outputTextView.string = ""
    }

    @objc private func sendPrompt() {
        guard chatProcess == nil else {
            return
        }
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            statusLabel.stringValue = "Enter a prompt first."
            return
        }

        guard let model = modelPopup.titleOfSelectedItem, !model.isEmpty else {
            statusLabel.stringValue = "Select a model first."
            return
        }

        let runtimeTemplate = runtimeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runtimeTemplate.isEmpty else {
            statusLabel.stringValue = "Set ANE runtime command template first."
            return
        }

        UserDefaults.standard.set(model, forKey: DefaultsKey.chatModel)
        UserDefaults.standard.set(runtimeTemplate, forKey: DefaultsKey.chatRuntimeTemplate)
        promptField.stringValue = ""

        appendOutput("\nYou: \(prompt)\nAssistant: ")
        streamStartedAt = Date()
        streamTokenApproxCount = 0

        var command = runtimeTemplate
            .replacingOccurrences(of: "{model}", with: shellQuote(model))
            .replacingOccurrences(of: "{prompt}", with: shellQuote(prompt))
            .replacingOccurrences(of: "{repo}", with: shellQuote(repoRoot))
        if !runtimeTemplate.contains("{prompt}") {
            command += " " + shellQuote(prompt)
        }

        if command.contains("{") && command.contains("}") {
            statusLabel.stringValue = "Runtime template has unresolved placeholders."
            appendOutput("\n[invalid runtime template]\n")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.environment = defaultShellEnvironment()
        if !repoRoot.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor in
                self?.appendOutput(text)
                self?.updateStreamingStatus(with: text)
            }
        }

        process.terminationHandler = { [weak self, weak pipe] proc in
            Task { @MainActor in
                pipe?.fileHandleForReading.readabilityHandler = nil
                self?.chatProcess = nil
                self?.sendButton.isEnabled = true
                self?.stopButton.isEnabled = false
                self?.streamStartedAt = nil
                self?.streamTokenApproxCount = 0
                if proc.terminationStatus == 0 {
                    self?.statusLabel.stringValue = "Completed."
                    self?.appendOutput("\n")
                } else {
                    self?.statusLabel.stringValue = "ANE chat command failed (\(proc.terminationStatus))."
                    self?.appendOutput("\n\n[chat failed]\n")
                }
            }
        }

        do {
            try process.run()
            chatProcess = process
            sendButton.isEnabled = false
            stopButton.isEnabled = true
            statusLabel.stringValue = "Streaming ANE response..."
        } catch {
            chatProcess = nil
            statusLabel.stringValue = "Could not launch ANE runtime command."
            appendOutput("\n[launch failed: \(error.localizedDescription)]\n")
        }
    }

    @objc private func stopChat() {
        chatProcess?.terminate()
    }

    private func appendOutput(_ text: String) {
        outputTextView.textStorage?.append(NSAttributedString(string: text))
        outputTextView.scrollToEndOfDocument(nil)
    }

    private func updateStreamingStatus(with chunk: String) {
        streamTokenApproxCount += chunk.split(whereSeparator: \.isWhitespace).count
        guard let started = streamStartedAt else {
            return
        }
        let elapsed = max(0.001, Date().timeIntervalSince(started))
        let tokPerSec = Double(streamTokenApproxCount) / elapsed
        statusLabel.stringValue = String(format: "Streaming... %.1f tok/s (approx)", tokPerSec)
    }
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

        return min(100, max(0, (used / total) * 100.0))
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
}

private final class LiveMetricsMenuView: NSView {
    private var history: [LiveMetricsSample] = []
    private let maxPoints = 150

    override var intrinsicContentSize: NSSize {
        NSSize(width: 432, height: 336)
    }

    func push(_ sample: LiveMetricsSample) {
        history.append(sample)
        if history.count > maxPoints {
            history.removeFirst(history.count - maxPoints)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let latest = history.last else {
            return
        }

        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let panelRect = bounds.insetBy(dx: 8, dy: 6)
        let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 10, yRadius: 10)
        if let gradient = NSGradient(colors: [
            NSColor.controlBackgroundColor.withAlphaComponent(0.86),
            NSColor.controlBackgroundColor.withAlphaComponent(0.62),
        ]) {
            gradient.draw(in: panelPath, angle: -90)
        } else {
            NSColor.controlBackgroundColor.withAlphaComponent(0.74).setFill()
            panelPath.fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        let inset = panelRect.insetBy(dx: 14, dy: 14)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let subtleTextAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let subtitle = latest.runActive && latest.telemetrySource != "idle"
            ? latest.telemetrySource
            : "M-series realtime telemetry"

        NSString(string: "Live Silicon Graph").draw(
            at: NSPoint(x: inset.minX, y: inset.maxY - 24),
            withAttributes: headerAttributes
        )
        drawBadge(
            text: subtitle,
            in: NSRect(x: inset.maxX - 210, y: inset.maxY - 28, width: 210, height: 22),
            fill: NSColor.tertiaryLabelColor.withAlphaComponent(0.12),
            stroke: NSColor.separatorColor.withAlphaComponent(0.18),
            attributes: subtleTextAttributes
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
        drawProgressRow(
            label: "ANE(live)",
            valueText: aneValue.map(percentText) ?? "n/a",
            value: aneValue ?? 0,
            color: .systemGreen,
            row: 3,
            in: inset,
            attributes: textAttributes,
            dimmed: aneValue == nil
        )

        let graphRect = NSRect(x: inset.minX, y: inset.minY + 4, width: inset.width, height: 136)
        drawGraph(in: graphRect, latest: latest)
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
        let rowTop = rect.maxY - 60 - CGFloat(row) * 31
        let labelWidth: CGFloat = 98
        let valueWidth: CGFloat = 62
        let barX = rect.minX + labelWidth + 10
        let barWidth = rect.width - labelWidth - valueWidth - 28
        let barRect = NSRect(x: barX, y: rowTop - 1, width: barWidth, height: 16)

        NSString(string: label).draw(
            at: NSPoint(x: rect.minX, y: rowTop - 5),
            withAttributes: attributes
        )
        NSString(string: valueText).draw(
            at: NSPoint(x: barRect.maxX + 10, y: rowTop - 5),
            withAttributes: attributes
        )

        let backgroundPath = NSBezierPath(roundedRect: barRect, xRadius: 6, yRadius: 6)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.18).setFill()
        backgroundPath.fill()

        let fillRatio = CGFloat(min(100, max(0, value)) / 100.0)
        let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: barRect.width * fillRatio, height: barRect.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 6, yRadius: 6)
        color.withAlphaComponent(dimmed ? 0.25 : 0.95).setFill()
        fillPath.fill()
    }

    private func drawGraph(in rect: NSRect, latest: LiveMetricsSample) {
        let background = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.16).setFill()
        background.fill()

        NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        border.lineWidth = 1
        border.stroke()

        let headerRect = NSRect(x: rect.minX + 8, y: rect.maxY - 28, width: rect.width - 16, height: 20)
        drawChipRow(
            labels: chartChipLabels(for: latest),
            in: headerRect
        )

        let plotRect = NSRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 2, height: rect.height - 30)
        drawHorizontalGridLines(in: plotRect)
        drawSeries(values: history.map(\.pCoreUsage), color: .systemOrange, in: plotRect)
        drawSeries(values: history.map(\.eCoreUsage), color: .systemBlue, in: plotRect)
        drawSeries(values: history.map(\.memoryUsage), color: .systemTeal, in: plotRect)
        if history.contains(where: { $0.aneUtilization != nil }) {
            drawSeries(values: history.map { $0.aneUtilization ?? 0 }, color: .systemGreen.withAlphaComponent(0.85), in: plotRect)
        }
    }

    private func chartChipLabels(for latest: LiveMetricsSample) -> [String] {
        let tflopsText: String
        if let tflops = latest.aneTFLOPS {
            tflopsText = String(format: "ANE %.2f TF", tflops)
        } else {
            tflopsText = "ANE TF n/a"
        }
        return [
            String(format: "Load %.2f", latest.load1m),
            String(format: "CPU %.1f%%", latest.totalCPUUsage),
            tflopsText,
        ]
    }

    private func drawChipRow(labels: [String], in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var x = rect.minX
        for label in labels {
            let measured = NSString(string: label).size(withAttributes: attributes)
            let chipWidth = min(rect.maxX - x, measured.width + 14)
            guard chipWidth > 12 else {
                break
            }
            let chipRect = NSRect(x: x, y: rect.minY, width: chipWidth, height: rect.height)
            drawBadge(
                text: label,
                in: chipRect,
                fill: NSColor.tertiaryLabelColor.withAlphaComponent(0.1),
                stroke: NSColor.separatorColor.withAlphaComponent(0.16),
                attributes: attributes
            )
            x += chipWidth + 8
            if x >= rect.maxX {
                break
            }
        }
    }

    private func drawBadge(
        text: String,
        in rect: NSRect,
        fill: NSColor,
        stroke: NSColor,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let size = NSString(string: text).size(withAttributes: attributes)
        let point = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2 + 1
        )
        NSString(string: text).draw(at: point, withAttributes: attributes)
    }

    private func drawHorizontalGridLines(in rect: NSRect) {
        let levels: [CGFloat] = [0.2, 0.4, 0.6, 0.8]
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
        guard values.count > 1 else {
            return
        }

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
        path.lineWidth = 2.6
        path.stroke()
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

@MainActor
final class ANEBarController: NSObject, NSApplicationDelegate {
    private enum DefaultsKey {
        static let repoRoot = "ane_repo_root"
        static let compactMenubar = "anebar_compact_menubar"
        static let compactLayout = "anebar_compact_layout"
        static let keepMenuOpen = "anebar_keep_menu_open"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var runFastItem = NSMenuItem()
    private var runFullItem = NSMenuItem()
    private var runBenchmarkItem = NSMenuItem()
    private var queueFastItem = NSMenuItem()
    private var queueFullItem = NSMenuItem()
    private var queueBenchmarkItem = NSMenuItem()
    private var queueSummaryItem = NSMenuItem()
    private var compactLayoutItem = NSMenuItem()
    private var compactMenubarItem = NSMenuItem()
    private var keepMenuOpenItem = NSMenuItem()

    private var statusLineItem = NSMenuItem()
    private var repoLineItem = NSMenuItem()
    private var profileLineItem = NSMenuItem()
    private var telemetryLineItem = NSMenuItem()
    private var guardrailItem = NSMenuItem()

    private var upstreamHeadItem = NSMenuItem()
    private var upstreamMetaItem = NSMenuItem()
    private var upstreamSyncItem = NSMenuItem()
    private var refreshUpstreamItem = NSMenuItem()

    private var modelSummaryItem = NSMenuItem()
    private var modelDeltaItem = NSMenuItem()
    private var modelDetailItems: [NSMenuItem] = []
    private var refreshModelsItem = NSMenuItem()

    private var historySummaryItem = NSMenuItem()
    private var historyDetailItem = NSMenuItem()
    private var historyDeltaItem = NSMenuItem()

    private var metricsView = LiveMetricsMenuView(frame: NSRect(x: 0, y: 0, width: 432, height: 336))
    private var telemetryWindowController: TelemetryWindowController?
    private var experimentsWindowController: ExperimentConsoleWindowController?
    private var historyWindowController: HistoryWindowController?
    private var chatWindowController: ChatWindowController?

    private let historyStore = RunHistoryStore()
    private let queueStore = RunQueueStore(baseDirectory: anebarDataDirectory())

    private var process: Process?
    private var activeQueueItemID: String?
    private var runStartedAt: Date?
    private var currentRunExperimentID: String?
    private var currentRunMode: String?
    private var currentRunTitle: String?
    private var currentRunCommand: String?
    private var currentRunWorkingDirectory: String?
    private var currentRunOutputLog: String = ""
    private var currentRunAneUtilization: Double?
    private var currentRunAneTFLOPS: Double?
    private var currentRunTotalTFLOPS: Double?
    private var currentRunAvgTrainMS: Double?
    private var currentRunTelemetrySource: String?

    private var lastExitCode: Int32?

    private var metricsSampler = SystemMetricsSampler()
    private var metricsTimer: Timer?
    private var latestMetrics: LiveMetricsSample?

    private var processOutputBuffer = ""
    private var lastANEUtilization: Double?
    private var lastANETflops: Double?
    private var lastANEUpdateAt: Date?

    private var lastModelCatalog: ModelCatalog?
    private var modelRefreshInFlight = false

    private var upstreamRefreshInFlight = false
    private var lastSeenRepoSHA: String?

    private var metricsTick: Int = 0
    private var repoProfile = RepoProfile(kind: .customFork, label: "custom-fork", detail: "Scanning repo…")
    private var experimentCatalog: [ExperimentDefinition] = []
    private var lastTelemetrySource: String?

    private var compactMenubar: Bool {
        get { boolDefault(key: DefaultsKey.compactMenubar, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.compactMenubar) }
    }

    private var compactLayout: Bool {
        get { boolDefault(key: DefaultsKey.compactLayout, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.compactLayout) }
    }

    private var keepMenuOpenAfterAction: Bool {
        get { boolDefault(key: DefaultsKey.keepMenuOpen, defaultValue: true) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.keepMenuOpen) }
    }

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

    private func boolDefault(key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupMenu()
        refreshInfoLines()
        refreshRunHistoryLines()
        startMetricsLoop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        metricsTimer?.invalidate()
        metricsTimer = nil
    }

    @objc private func noopMenuItemAction(_ sender: Any?) {}

    private func configureInfoItem(_ item: NSMenuItem) {
        item.target = self
        item.action = #selector(noopMenuItemAction(_:))
        item.isEnabled = true
    }

    @objc private func toggleCompactLayout() {
        compactLayout.toggle()
        applyMenuDensity()
        reopenMenuIfNeeded()
    }

    @objc private func toggleCompactMenubar() {
        compactMenubar.toggle()
        compactMenubarItem.state = compactMenubar ? .on : .off
        updateStatusButton()
        reopenMenuIfNeeded()
    }

    @objc private func toggleKeepMenuOpen() {
        keepMenuOpenAfterAction.toggle()
        keepMenuOpenItem.state = keepMenuOpenAfterAction ? .on : .off
        if keepMenuOpenAfterAction {
            reopenMenuIfNeeded()
        }
    }

    private func reopenMenuIfNeeded() {
        guard keepMenuOpenAfterAction, let button = statusItem.button else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak button] in
            guard let self, self.keepMenuOpenAfterAction else {
                return
            }
            guard let button else {
                return
            }
            button.performClick(nil)
        }
    }

    private func applyMenuDensity() {
        compactLayoutItem.state = compactLayout ? .on : .off
        let hideAdvanced = compactLayout
        let advancedItems = [repoLineItem, upstreamHeadItem, upstreamMetaItem, upstreamSyncItem, refreshUpstreamItem, modelDeltaItem, refreshModelsItem, historyDetailItem, historyDeltaItem]
        for item in advancedItems {
            item.isHidden = hideAdvanced
        }
        for item in modelDetailItems {
            item.isHidden = hideAdvanced || item.title.isEmpty
        }
    }

    private func setupStatusItem() {
        if let button = statusItem.button {
            button.title = ""
            button.toolTip = "ANEBar"
            if let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "ANEBar") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = compactMenubar ? .imageOnly : .imageLeading
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

        let viewMenuItem = NSMenuItem(title: "View Options", action: nil, keyEquivalent: "")
        let viewSubmenu = NSMenu(title: "View Options")
        viewMenuItem.submenu = viewSubmenu
        menu.addItem(viewMenuItem)

        compactLayoutItem = NSMenuItem(title: "Compact Menu Layout", action: #selector(toggleCompactLayout), keyEquivalent: "")
        compactLayoutItem.target = self
        viewSubmenu.addItem(compactLayoutItem)

        compactMenubarItem = NSMenuItem(title: "Compact Menubar Label", action: #selector(toggleCompactMenubar), keyEquivalent: "")
        compactMenubarItem.target = self
        viewSubmenu.addItem(compactMenubarItem)

        keepMenuOpenItem = NSMenuItem(title: "Keep Menu Open After Click", action: #selector(toggleKeepMenuOpen), keyEquivalent: "")
        keepMenuOpenItem.target = self
        viewSubmenu.addItem(keepMenuOpenItem)
        menu.addItem(.separator())

        statusLineItem = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        configureInfoItem(statusLineItem)
        menu.addItem(statusLineItem)

        repoLineItem = NSMenuItem(title: "Repo: \(repoRoot)", action: nil, keyEquivalent: "")
        configureInfoItem(repoLineItem)
        menu.addItem(repoLineItem)

        profileLineItem = NSMenuItem(title: "Profile: scanning…", action: nil, keyEquivalent: "")
        configureInfoItem(profileLineItem)
        menu.addItem(profileLineItem)

        telemetryLineItem = NSMenuItem(title: "Telemetry: idle", action: nil, keyEquivalent: "")
        configureInfoItem(telemetryLineItem)
        menu.addItem(telemetryLineItem)

        guardrailItem = NSMenuItem(title: "Guardrails: checking…", action: nil, keyEquivalent: "")
        configureInfoItem(guardrailItem)
        menu.addItem(guardrailItem)

        queueSummaryItem = NSMenuItem(title: "Queue: 0 pending", action: nil, keyEquivalent: "")
        configureInfoItem(queueSummaryItem)
        menu.addItem(queueSummaryItem)

        modelSummaryItem = NSMenuItem(title: "Models: scanning…", action: nil, keyEquivalent: "")
        configureInfoItem(modelSummaryItem)
        menu.addItem(modelSummaryItem)

        historySummaryItem = NSMenuItem(title: "Run history: none", action: nil, keyEquivalent: "")
        configureInfoItem(historySummaryItem)
        menu.addItem(historySummaryItem)

        historyDetailItem = NSMenuItem(title: "Last metrics: n/a", action: nil, keyEquivalent: "")
        configureInfoItem(historyDetailItem)
        menu.addItem(historyDetailItem)

        historyDeltaItem = NSMenuItem(title: "Comparison: n/a", action: nil, keyEquivalent: "")
        configureInfoItem(historyDeltaItem)
        menu.addItem(historyDeltaItem)

        upstreamHeadItem = NSMenuItem(title: "HEAD: scanning…", action: nil, keyEquivalent: "")
        configureInfoItem(upstreamHeadItem)
        menu.addItem(upstreamHeadItem)

        upstreamMetaItem = NSMenuItem(title: "Repo status: unknown", action: nil, keyEquivalent: "")
        configureInfoItem(upstreamMetaItem)
        menu.addItem(upstreamMetaItem)

        upstreamSyncItem = NSMenuItem(title: "Sync: unknown", action: nil, keyEquivalent: "")
        configureInfoItem(upstreamSyncItem)
        menu.addItem(upstreamSyncItem)

        refreshUpstreamItem = NSMenuItem(title: "Refresh Repo Head", action: #selector(refreshUpstreamManual), keyEquivalent: "u")
        refreshUpstreamItem.target = self

        menu.addItem(.separator())

        modelDeltaItem = NSMenuItem(title: "Model delta: baseline", action: nil, keyEquivalent: "")
        configureInfoItem(modelDeltaItem)
        menu.addItem(modelDeltaItem)

        for _ in 0..<6 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            configureInfoItem(item)
            item.isHidden = true
            modelDetailItems.append(item)
            menu.addItem(item)
        }

        refreshModelsItem = NSMenuItem(title: "Refresh Model Index", action: #selector(refreshModelIndexManual), keyEquivalent: "m")
        refreshModelsItem.target = self

        menu.addItem(.separator())

        let openExperimentsItem = NSMenuItem(title: "Open Experiment Console", action: #selector(openExperimentConsole), keyEquivalent: "x")
        openExperimentsItem.target = self
        menu.addItem(openExperimentsItem)

        let openTelemetryItem = NSMenuItem(title: "Open Telemetry Panel", action: #selector(openTelemetryPanel), keyEquivalent: "t")
        openTelemetryItem.target = self
        menu.addItem(openTelemetryItem)

        let openHistoryItem = NSMenuItem(title: "Open History", action: #selector(openHistoryPanel), keyEquivalent: "j")
        openHistoryItem.target = self
        menu.addItem(openHistoryItem)

        let actionsMenuItem = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
        let actionsSubmenu = NSMenu(title: "Quick Actions")
        actionsMenuItem.submenu = actionsSubmenu
        menu.addItem(actionsMenuItem)

        runFastItem = NSMenuItem(title: RunPreset.fast.menuTitle, action: #selector(runFastPipeline), keyEquivalent: "r")
        runFastItem.target = self
        actionsSubmenu.addItem(runFastItem)

        runFullItem = NSMenuItem(title: RunPreset.full.menuTitle, action: #selector(runFullPipeline), keyEquivalent: "R")
        runFullItem.target = self
        actionsSubmenu.addItem(runFullItem)

        runBenchmarkItem = NSMenuItem(title: RunPreset.benchmark.menuTitle, action: #selector(runBenchmarkPipeline), keyEquivalent: "b")
        runBenchmarkItem.target = self
        actionsSubmenu.addItem(runBenchmarkItem)
        actionsSubmenu.addItem(.separator())

        queueFastItem = NSMenuItem(title: "Queue Fast", action: #selector(queueFastRun), keyEquivalent: "")
        queueFastItem.target = self
        actionsSubmenu.addItem(queueFastItem)

        queueFullItem = NSMenuItem(title: "Queue Full", action: #selector(queueFullRun), keyEquivalent: "")
        queueFullItem.target = self
        actionsSubmenu.addItem(queueFullItem)

        queueBenchmarkItem = NSMenuItem(title: "Queue Benchmark (+10m)", action: #selector(queueBenchmarkRunDelayed), keyEquivalent: "")
        queueBenchmarkItem.target = self
        actionsSubmenu.addItem(queueBenchmarkItem)

        let clearQueueItem = NSMenuItem(title: "Clear Pending Queue", action: #selector(clearPendingQueue), keyEquivalent: "")
        clearQueueItem.target = self
        actionsSubmenu.addItem(clearQueueItem)
        actionsSubmenu.addItem(.separator())

        let openChatItem = NSMenuItem(title: "Open ANE Chat", action: #selector(openLocalChat), keyEquivalent: "l")
        openChatItem.target = self
        actionsSubmenu.addItem(openChatItem)

        let stopItem = NSMenuItem(title: "Stop Running Job", action: #selector(stopJob), keyEquivalent: "s")
        stopItem.target = self
        actionsSubmenu.addItem(stopItem)

        let reportsMenuItem = NSMenuItem(title: "Reports & Files", action: nil, keyEquivalent: "")
        let reportsSubmenu = NSMenu(title: "Reports & Files")
        reportsMenuItem.submenu = reportsSubmenu
        menu.addItem(reportsMenuItem)

        let openHistoryJSONItem = NSMenuItem(title: "Open Run History JSON", action: #selector(openRunHistoryFile), keyEquivalent: "")
        openHistoryJSONItem.target = self
        reportsSubmenu.addItem(openHistoryJSONItem)

        let exportBundleItem = NSMenuItem(title: "Export Repro Bundle", action: #selector(exportReproBundle), keyEquivalent: "e")
        exportBundleItem.target = self
        reportsSubmenu.addItem(exportBundleItem)

        let openBenchmarkSummaryItem = NSMenuItem(title: "Open Benchmark Summary", action: #selector(openBenchmarkSummary), keyEquivalent: "k")
        openBenchmarkSummaryItem.target = self
        reportsSubmenu.addItem(openBenchmarkSummaryItem)

        let openResultsItem = NSMenuItem(title: "Open Results Folder", action: #selector(openResultsFolder), keyEquivalent: "o")
        openResultsItem.target = self
        reportsSubmenu.addItem(openResultsItem)

        reportsSubmenu.addItem(.separator())
        reportsSubmenu.addItem(refreshUpstreamItem)
        reportsSubmenu.addItem(refreshModelsItem)

        let mediaMenuItem = NSMenuItem(title: "Studio Assets", action: nil, keyEquivalent: "")
        let mediaSubmenu = NSMenu(title: "Studio Assets")
        mediaMenuItem.submenu = mediaSubmenu
        menu.addItem(mediaMenuItem)

        let openHeroItem = NSMenuItem(title: "Open Hero Graphic", action: #selector(openHeroGraphic), keyEquivalent: "h")
        openHeroItem.target = self
        mediaSubmenu.addItem(openHeroItem)

        let openSignalItem = NSMenuItem(title: "Open Community Spotlight Graphic", action: #selector(openSpotlightGraphic), keyEquivalent: "g")
        openSignalItem.target = self
        mediaSubmenu.addItem(openSignalItem)

        let copyPostItem = NSMenuItem(title: "Copy Today Post", action: #selector(copyTodayPost), keyEquivalent: "c")
        copyPostItem.target = self
        mediaSubmenu.addItem(copyPostItem)

        menu.addItem(.separator())

        let chooseRepoItem = NSMenuItem(title: "Choose Repo Root…", action: #selector(chooseRepoRoot), keyEquivalent: "")
        chooseRepoItem.target = self
        menu.addItem(chooseRepoItem)

        let quitItem = NSMenuItem(title: "Quit ANEBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        compactLayoutItem.state = compactLayout ? .on : .off
        compactMenubarItem.state = compactMenubar ? .on : .off
        keepMenuOpenItem.state = keepMenuOpenAfterAction ? .on : .off
        applyMenuDensity()
    }

    private func refreshInfoLines() {
        repoLineItem.title = "Repo: \(abbreviatedPath(repoRoot, maxLength: 54))"
        repoLineItem.toolTip = repoRoot
        if let code = lastExitCode {
            statusLineItem.title = code == 0 ? "Status: last run succeeded" : "Status: last run failed (\(code))"
        }
        refreshRepoContext()
        refreshTelemetryLine()
        refreshGuardrailLine()
        refreshModelIndex(force: true)
        refreshUpstreamInfo(force: true)
        refreshQueueSummary()
        refreshRunHistoryLines()
        applyMenuDensity()
    }

    private func setRunning(_ running: Bool, message: String) {
        runFastItem.isEnabled = !running
        runFullItem.isEnabled = !running
        runBenchmarkItem.isEnabled = !running
        queueFastItem.isEnabled = !running
        queueFullItem.isEnabled = !running
        queueBenchmarkItem.isEnabled = !running
        experimentsWindowController?.setBusy(running)
        historyWindowController?.setBusy(running)
        statusLineItem.title = "Status: \(message)"
        updateStatusButton()
    }

    private func refreshRepoContext() {
        repoProfile = detectRepoProfile(in: repoRoot)
        experimentCatalog = discoverExperimentCatalog(in: repoRoot, profile: repoProfile)
        let runnableCount = experimentCatalog.filter(\.isRunnable).count
        let advancedCount = experimentCatalog.filter(\.advanced).count
        profileLineItem.title = "Profile: \(repoProfile.label) | \(runnableCount) runnable | \(advancedCount) advanced"
        profileLineItem.toolTip = repoProfile.detail
        experimentsWindowController?.update(profile: repoProfile, repoRoot: repoRoot, experiments: experimentCatalog)
        experimentsWindowController?.setBusy(process != nil)
        telemetryWindowController?.updateContext(
            repoProfile: repoProfile,
            repoRoot: repoRoot,
            currentRunTitle: currentRunTitle,
            telemetrySource: currentRunTelemetrySource ?? lastTelemetrySource
        )
    }

    private func refreshTelemetryLine() {
        let source = currentRunTelemetrySource ?? lastTelemetrySource ?? "idle"
        telemetryLineItem.title = "Telemetry: \(source)"
        telemetryWindowController?.updateContext(
            repoProfile: repoProfile,
            repoRoot: repoRoot,
            currentRunTitle: currentRunTitle,
            telemetrySource: source
        )
    }

    private func setTelemetrySource(_ source: String, persistAsLast: Bool = true) {
        currentRunTelemetrySource = source
        if persistAsLast {
            lastTelemetrySource = source
        }
        refreshTelemetryLine()
    }

    private func experimentByID(_ id: String) -> ExperimentDefinition? {
        experimentCatalog.first { $0.id == id }
    }

    private func wrappedLegacyExperiment(from base: ExperimentDefinition, preset: RunPreset, title: String, runCommand: String?) -> ExperimentDefinition {
        var wrapped = base
        wrapped.id = "preset.\(preset.rawValue)"
        wrapped.title = title
        wrapped.summary = "Legacy preset wrapper around \(base.title)."
        wrapped.runCommand = runCommand
        return wrapped
    }

    private func experiment(for preset: RunPreset) -> ExperimentDefinition? {
        if repoProfile.kind == .labEnhanced, let lab = experimentByID("lab_research") {
            switch preset {
            case .fast:
                return wrappedLegacyExperiment(
                    from: lab,
                    preset: preset,
                    title: "Fast Preset",
                    runCommand: "uv run python training/research/run_research.py --qos-runs 2 --skip-build"
                )
            case .full:
                return wrappedLegacyExperiment(
                    from: lab,
                    preset: preset,
                    title: "Full Preset",
                    runCommand: "uv run python training/research/run_research.py --qos-runs 3"
                )
            case .benchmark:
                return wrappedLegacyExperiment(
                    from: lab,
                    preset: preset,
                    title: "Benchmark Preset",
                    runCommand: "uv run python training/research/run_research.py --qos-runs 5"
                )
            }
        }

        if preset == .benchmark, let peak = experimentByID("inmem_peak") {
            return wrappedLegacyExperiment(
                from: peak,
                preset: preset,
                title: "Benchmark Preset",
                runCommand: peak.runCommand
            )
        }

        if let training = experimentByID("train_large_ane") ?? experimentByID("train_large") {
            let binary = training.id == "train_large_ane" ? "train_large_ane" : "train_large"
            let steps: Int
            let title: String
            switch preset {
            case .fast:
                steps = 40
                title = "Fast Preset"
            case .full:
                steps = 200
                title = "Full Preset"
            case .benchmark:
                steps = 100
                title = "Benchmark Preset"
            }
            return wrappedLegacyExperiment(
                from: training,
                preset: preset,
                title: title,
                runCommand: "./training/\(binary) --steps \(steps) --lr 1e-4"
            )
        }

        if let fallback = experimentCatalog.first(where: \.isRunnable) {
            return wrappedLegacyExperiment(
                from: fallback,
                preset: preset,
                title: preset.menuTitle,
                runCommand: fallback.runCommand
            )
        }

        return nil
    }

    private func runResolvedCommand(
        experimentID: String?,
        mode: String,
        title: String,
        command: String,
        workingDirectory: String,
        queueItemID: String? = nil
    ) {
        guard process == nil else {
            return
        }
        currentRunExperimentID = experimentID
        currentRunMode = mode
        currentRunTitle = title
        currentRunCommand = command
        currentRunWorkingDirectory = workingDirectory
        currentRunOutputLog = ""
        currentRunAneUtilization = nil
        currentRunAneTFLOPS = nil
        currentRunTotalTFLOPS = nil
        currentRunAvgTrainMS = nil
        currentRunTelemetrySource = "awaiting output"
        lastANEUtilization = nil
        lastANETflops = nil
        lastANEUpdateAt = nil
        refreshTelemetryLine()
        processOutputBuffer = ""
        runStartedAt = Date()
        activeQueueItemID = queueItemID

        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]
        proc.environment = defaultShellEnvironment()

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

        setRunning(true, message: "running \(title)")
        process = proc

        proc.terminationHandler = { [weak self, weak pipe] finished in
            Task { @MainActor in
                pipe?.fileHandleForReading.readabilityHandler = nil
                self?.process = nil
                self?.lastExitCode = finished.terminationStatus

                let succeeded = finished.terminationStatus == 0
                self?.setRunning(false, message: succeeded ? "idle" : "error")
                self?.persistRunResult(exitCode: finished.terminationStatus)
                self?.refreshInfoLines()
            }
        }

        do {
            try proc.run()
        } catch {
            process = nil
            lastExitCode = 1
            setRunning(false, message: "launch failed")
            persistRunResult(exitCode: 1)
            refreshInfoLines()
        }
    }

    private func runPreset(_ preset: RunPreset, queueItemID: String? = nil) {
        guard let experiment = experiment(for: preset) else {
            statusLineItem.title = "Status: no matching run command for repo"
            return
        }
        runExperiment(experiment, queueItemID: queueItemID)
    }

    private func guardrailBlockReason(for experiment: ExperimentDefinition) -> String? {
        switch experiment.group {
        case .validation, .bridge:
            return nil
        case .peak, .training, .dynamic, .lab:
            break
        }

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            return "thermal \(thermalLabel(thermal))"
        }
        let battery = readBatteryStatus()
        if let percent = battery.percent, !battery.isCharging, percent < 30 {
            return "battery \(percent)% and unplugged"
        }
        return nil
    }

    private func runExperiment(_ experiment: ExperimentDefinition, queueItemID: String? = nil) {
        guard let command = experiment.resolvedCommand(repoRoot: repoRoot) else {
            statusLineItem.title = "Status: \(experiment.title) is catalogued only"
            return
        }
        let missing = missingPrerequisites(for: experiment, repoRoot: repoRoot)
        if !missing.isEmpty {
            statusLineItem.title = "Status: missing " + missing.joined(separator: ", ")
            return
        }
        if let reason = guardrailBlockReason(for: experiment) {
            statusLineItem.title = "Status: blocked by guardrail (\(reason))"
            refreshGuardrailLine()
            return
        }
        runResolvedCommand(
            experimentID: experiment.id,
            mode: experiment.runLabel,
            title: experiment.title,
            command: command,
            workingDirectory: experiment.resolvedWorkingDirectory(repoRoot: repoRoot),
            queueItemID: queueItemID
        )
    }

    private func queueExperiment(_ experiment: ExperimentDefinition, delaySeconds: TimeInterval = 0) {
        guard experiment.isRunnable else {
            statusLineItem.title = "Status: \(experiment.title) is catalogued only"
            return
        }
        let missing = missingPrerequisites(for: experiment, repoRoot: repoRoot)
        if !missing.isEmpty {
            statusLineItem.title = "Status: missing " + missing.joined(separator: ", ")
            return
        }
        _ = queueStore.enqueue(experiment: experiment, delaySeconds: delaySeconds)
        refreshQueueSummary()
        statusLineItem.title = delaySeconds > 0
            ? "Status: queued \(experiment.title) (+\(Int(delaySeconds / 60))m)"
            : "Status: queued \(experiment.title)"
    }

    private func copyCommandForExperiment(_ experiment: ExperimentDefinition) -> String? {
        if let command = experiment.resolvedCommand(repoRoot: repoRoot) {
            return "cd \(shellQuote(experiment.resolvedWorkingDirectory(repoRoot: repoRoot))) && \(command)"
        }
        return experiment.sourcePath
    }

    private func persistRunResult(exitCode: Int32) {
        guard let mode = currentRunMode,
              let command = currentRunCommand,
              let startedAt = runStartedAt
        else {
            currentRunExperimentID = nil
            currentRunMode = nil
            currentRunTitle = nil
            currentRunCommand = nil
            currentRunWorkingDirectory = nil
            currentRunOutputLog = ""
            currentRunTelemetrySource = nil
            runStartedAt = nil
            return
        }

        hydrateMetricsFromResearchArtifactsIfNeeded(command: command)
        applyCapturedOutputMetricsIfNeeded(experimentID: currentRunExperimentID, output: currentRunOutputLog)

        let endedAt = Date()
        let duration = endedAt.timeIntervalSince(startedAt)

        let record = RunRecord(
            id: UUID().uuidString,
            mode: mode,
            experimentID: currentRunExperimentID,
            group: currentRunExperimentID.flatMap { experimentByID($0)?.group.rawValue },
            title: currentRunTitle,
            command: command,
            repoRoot: repoRoot,
            workingDirectory: currentRunWorkingDirectory,
            repoHead: lastSeenRepoSHA,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            exitCode: exitCode,
            aneUtilization: currentRunAneUtilization,
            aneTFLOPS: currentRunAneTFLOPS,
            totalTFLOPS: currentRunTotalTFLOPS,
            avgTrainMS: currentRunAvgTrainMS,
            telemetrySource: currentRunTelemetrySource == "awaiting output" ? nil : currentRunTelemetrySource
        )

        historyStore.append(record)
        if let activeQueueItemID {
            queueStore.markFinished(id: activeQueueItemID, exitCode: exitCode)
        }
        _ = writeBenchmarkSummaryFile()
        refreshRunHistoryLines()
        refreshQueueSummary()

        currentRunExperimentID = nil
        currentRunMode = nil
        currentRunTitle = nil
        currentRunCommand = nil
        currentRunWorkingDirectory = nil
        currentRunOutputLog = ""
        currentRunTelemetrySource = nil
        runStartedAt = nil
        activeQueueItemID = nil
        refreshTelemetryLine()
    }

    @objc private func runFastPipeline() {
        runPreset(.fast)
        reopenMenuIfNeeded()
    }

    @objc private func runFullPipeline() {
        runPreset(.full)
        reopenMenuIfNeeded()
    }

    @objc private func runBenchmarkPipeline() {
        runPreset(.benchmark)
        reopenMenuIfNeeded()
    }

    @objc private func queueFastRun() {
        if let experiment = experiment(for: .fast) {
            queueExperiment(experiment)
        } else {
            _ = queueStore.enqueue(preset: .fast)
            refreshQueueSummary()
            statusLineItem.title = "Status: queued fast preset"
        }
        reopenMenuIfNeeded()
    }

    @objc private func queueFullRun() {
        if let experiment = experiment(for: .full) {
            queueExperiment(experiment)
        } else {
            _ = queueStore.enqueue(preset: .full)
            refreshQueueSummary()
            statusLineItem.title = "Status: queued full preset"
        }
        reopenMenuIfNeeded()
    }

    @objc private func queueBenchmarkRunDelayed() {
        if let experiment = experiment(for: .benchmark) {
            queueExperiment(experiment, delaySeconds: 10 * 60)
        } else {
            _ = queueStore.enqueue(preset: .benchmark, delaySeconds: 10 * 60)
            refreshQueueSummary()
            statusLineItem.title = "Status: queued benchmark (+10m)"
        }
        reopenMenuIfNeeded()
    }

    @objc private func clearPendingQueue() {
        queueStore.cancelAllPending()
        refreshQueueSummary()
        statusLineItem.title = "Status: cleared pending queue"
        reopenMenuIfNeeded()
    }

    @objc private func openExperimentConsole() {
        if experimentsWindowController == nil {
            let controller = ExperimentConsoleWindowController()
            controller.onRunExperiment = { [weak self] experiment in
                self?.runExperiment(experiment)
            }
            controller.onQueueExperiment = { [weak self] experiment in
                self?.queueExperiment(experiment)
            }
            controller.onCopyExperimentCommand = { [weak self] experiment in
                self?.copyCommandForExperiment(experiment)
            }
            controller.onRefresh = { [weak self] in
                self?.refreshRepoContext()
            }
            experimentsWindowController = controller
        }
        refreshRepoContext()
        experimentsWindowController?.setBusy(process != nil)
        experimentsWindowController?.showWindow(nil)
        experimentsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reopenMenuIfNeeded()
    }

    @objc private func openTelemetryPanel() {
        if telemetryWindowController == nil {
            telemetryWindowController = TelemetryWindowController()
        }
        telemetryWindowController?.updateContext(
            repoProfile: repoProfile,
            repoRoot: repoRoot,
            currentRunTitle: currentRunTitle,
            telemetrySource: currentRunTelemetrySource ?? lastTelemetrySource
        )
        if let latestMetrics {
            telemetryWindowController?.push(sample: latestMetrics)
        }
        telemetryWindowController?.showWindow(nil)
        telemetryWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reopenMenuIfNeeded()
    }

    @objc private func openHistoryPanel() {
        if historyWindowController == nil {
            let controller = HistoryWindowController()
            controller.onRerun = { [weak self] record in
                self?.rerunRecord(record)
            }
            controller.onCopyCommand = { [weak self] record in
                self?.copyCommandForRecord(record)
            }
            controller.onExportRepro = { [weak self] in
                self?.exportReproBundle()
            }
            controller.onOpenSummary = { [weak self] in
                self?.openBenchmarkSummary()
            }
            controller.onOpenHistoryJSON = { [weak self] in
                self?.openRunHistoryFile()
            }
            controller.onCopySocialSnippet = { [weak self] record, compare in
                self?.socialSnippet(for: record, comparedTo: compare)
            }
            historyWindowController = controller
        }
        historyWindowController?.update(records: historyStore.recentDescending(limit: 120), repoRoot: repoRoot)
        historyWindowController?.setBusy(process != nil)
        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reopenMenuIfNeeded()
    }

    @objc private func openLocalChat() {
        if chatWindowController == nil {
            chatWindowController = ChatWindowController()
        }
        chatWindowController?.setRepoRoot(repoRoot)
        let fallbackModels = lastModelCatalog?.artifacts
            .prefix(8)
            .map { URL(fileURLWithPath: $0.relativePath).deletingPathExtension().lastPathComponent } ?? []
        chatWindowController?.setFallbackModels(fallbackModels)
        chatWindowController?.showWindow(nil)
        chatWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reopenMenuIfNeeded()
    }

    @objc private func stopJob() {
        process?.terminate()
        reopenMenuIfNeeded()
    }

    @objc private func openResultsFolder() {
        let candidates = [
            "\(repoRoot)/training/research/results",
            "\(repoRoot)/training",
            repoRoot,
        ]
        openFirstExistingPath(candidates)
        reopenMenuIfNeeded()
    }

    @objc private func openHeroGraphic() {
        let candidates = [
            "\(repoRoot)/training/research/results/figures/ane_hero_card_instagram.png",
            "\(repoRoot)/training/dashboard.gif",
            "\(repoRoot)/README.md",
        ]
        openFirstExistingPath(candidates)
        reopenMenuIfNeeded()
    }

    @objc private func openSpotlightGraphic() {
        let candidates = [
            "\(repoRoot)/training/research/results/figures/ecosystem_spotlight_card_instagram.png",
            "\(repoRoot)/training/m5result.md",
            "\(repoRoot)/README.md",
        ]
        openFirstExistingPath(candidates)
        reopenMenuIfNeeded()
    }

    @objc private func copyTodayPost() {
        let candidates = [
            "\(repoRoot)/training/research/results/content/today_post_premium.md",
            "\(repoRoot)/training/research/results/content/today_post.md",
        ]

        for path in candidates {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                statusLineItem.title = "Status: post draft copied"
                reopenMenuIfNeeded()
                return
            }
        }

        statusLineItem.title = "Status: could not find post draft"
        reopenMenuIfNeeded()
    }

    @objc private func openRunHistoryFile() {
        NSWorkspace.shared.open(historyStore.fileURL)
        reopenMenuIfNeeded()
    }

    private func rerunRecord(_ record: RunRecord) {
        guard process == nil else {
            statusLineItem.title = "Status: already running a job"
            return
        }
        let workingDirectory: String
        if let saved = record.workingDirectory, !saved.isEmpty {
            workingDirectory = saved
        } else if let experimentID = record.experimentID, let experiment = experimentByID(experimentID) {
            workingDirectory = experiment.resolvedWorkingDirectory(repoRoot: repoRoot)
        } else {
            workingDirectory = record.repoRoot
        }
        runResolvedCommand(
            experimentID: record.experimentID,
            mode: record.mode,
            title: record.title ?? record.mode,
            command: record.command,
            workingDirectory: workingDirectory
        )
    }

    private func copyCommandForRecord(_ record: RunRecord) -> String {
        if let experimentID = record.experimentID, let experiment = experimentByID(experimentID), let command = copyCommandForExperiment(experiment) {
            return command
        }
        let workingDirectory = (record.workingDirectory?.isEmpty == false ? record.workingDirectory : record.repoRoot) ?? record.repoRoot
        return "cd \(shellQuote(workingDirectory)) && \(record.command)"
    }

    private func socialSnippet(for record: RunRecord, comparedTo compare: RunRecord?) -> String {
        var parts: [String] = []
        parts.append(record.title ?? record.mode)
        if let tflops = record.aneTFLOPS {
            parts.append(String(format: "ANE %.2f TFLOPS", tflops))
        }
        if let util = record.aneUtilization {
            parts.append(String(format: "util %.1f%%", util))
        }
        if let avgTrainMS = record.avgTrainMS {
            parts.append(String(format: "avg %.1f ms", avgTrainMS))
        }
        if let compare,
           let latest = record.aneTFLOPS,
           let previous = compare.aneTFLOPS
        {
            parts.append("delta " + formatSigned(latest - previous, suffix: " TFLOPS"))
        }
        if let head = record.repoHead, !head.isEmpty {
            parts.append("head \(head)")
        }
        return parts.joined(separator: " | ")
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
            refreshUpstreamInfo(force: true)
        }
    }

    @objc private func refreshModelIndexManual() {
        refreshModelIndex(force: true)
        reopenMenuIfNeeded()
    }

    @objc private func refreshUpstreamManual() {
        refreshUpstreamInfo(force: true)
        reopenMenuIfNeeded()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openFirstExistingPath(_ candidates: [String]) {
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        statusLineItem.title = "Status: path not found"
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
        if metricsTick % 30 == 0 {
            refreshUpstreamInfo(force: false)
        }
        if metricsTick % 60 == 0 {
            refreshRepoContext()
        }
        if metricsTick % 5 == 0, let command = currentRunCommand {
            hydrateMetricsFromResearchArtifactsIfNeeded(command: command)
        }
        runDueQueueIfNeeded()

        guard let cpu = metricsSampler.sampleCPU() else {
            return
        }

        let liveTelemetry = isLiveTelemetrySource(currentRunTelemetrySource ?? lastTelemetrySource)
        let sample = LiveMetricsSample(
            timestamp: Date(),
            totalCPUUsage: cpu.total,
            pCoreUsage: cpu.pCores,
            eCoreUsage: cpu.eCores,
            memoryUsage: metricsSampler.sampleMemoryPercent(),
            load1m: metricsSampler.sampleLoadAverage1m(),
            aneUtilization: liveTelemetry ? activeANEUtilization() : nil,
            aneTFLOPS: liveTelemetry ? activeANETflops() : nil,
            telemetrySource: currentRunTelemetrySource ?? lastTelemetrySource ?? "idle",
            runActive: process != nil
        )

        latestMetrics = sample
        metricsView.push(sample)
        telemetryWindowController?.push(sample: sample)
        refreshGuardrailLine()
        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        let running = process != nil
        if let image = NSImage(systemSymbolName: running ? "cpu.fill" : "cpu", accessibilityDescription: "ANEBar") {
            image.isTemplate = true
            button.image = image
        }

        button.imagePosition = compactMenubar ? .imageOnly : .imageLeading

        guard let latestMetrics else {
            button.title = compactMenubar ? "" : (running ? "ANE*" : "ANE")
            button.toolTip = "ANEBar"
            return
        }

        if compactMenubar {
            button.title = ""
        } else {
            let prefix = running ? "ANE*" : "ANE"
            button.title = String(format: "%@ %.0f/%.0f", prefix, latestMetrics.pCoreUsage, latestMetrics.eCoreUsage)
        }

        button.toolTip = String(
            format: "P %.1f%%  E %.1f%%  Mem %.1f%%  Load %.2f",
            latestMetrics.pCoreUsage,
            latestMetrics.eCoreUsage,
            latestMetrics.memoryUsage,
            latestMetrics.load1m
        )
    }

    private func consumeProcessOutput(_ chunk: String) {
        currentRunOutputLog.append(chunk)
        processOutputBuffer.append(chunk)
        while let newline = processOutputBuffer.range(of: "\n") {
            let line = String(processOutputBuffer[..<newline.lowerBound])
            processOutputBuffer.removeSubrange(..<newline.upperBound)
            parseMetricsLine(line)
        }
    }

    private func parseMetricsLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String
        {
            switch type {
            case "perf":
                if let aneTFLOPS = json["ane_tflops"] as? Double {
                    lastANETflops = aneTFLOPS
                    currentRunAneTFLOPS = aneTFLOPS
                    lastANEUpdateAt = Date()
                }
                if let utilization = json["ane_util_pct"] as? Double {
                    lastANEUtilization = utilization
                    currentRunAneUtilization = utilization
                    lastANEUpdateAt = Date()
                }
                setTelemetrySource("live JSON stream")
            case "batch":
                if let msPerStep = json["ms_per_step"] as? Double {
                    currentRunAvgTrainMS = msPerStep
                }
                setTelemetrySource("live JSON stream")
            case "step":
                setTelemetrySource("live JSON stream")
            default:
                break
            }
        }

        if let utilization = captureDouble(in: line, pattern: #"ANE utilization:\s*([0-9]+(?:\.[0-9]+)?)%"#) {
            lastANEUtilization = utilization
            currentRunAneUtilization = utilization
            lastANEUpdateAt = Date()
            setTelemetrySource("stdout summary")
        }

        if let aneTFLOPS = captureDouble(in: line, pattern: #"ANE TFLOPS:\s*([0-9]+(?:\.[0-9]+)?)"#) {
            lastANETflops = aneTFLOPS
            currentRunAneTFLOPS = aneTFLOPS
            lastANEUpdateAt = Date()
            setTelemetrySource("stdout summary")
        }

        if let totalTFLOPS = captureDouble(in: line, pattern: #"Total TFLOPS:\s*([0-9]+(?:\.[0-9]+)?)"#) {
            currentRunTotalTFLOPS = totalTFLOPS
            setTelemetrySource("stdout summary")
        }

        if let avgTrainMS = captureDouble(in: line, pattern: #"Avg train:\s*([0-9]+(?:\.[0-9]+)?)\s*ms/step"#) {
            currentRunAvgTrainMS = avgTrainMS
            setTelemetrySource("stdout summary")
        }
    }

    private func activeANEUtilization() -> Double? {
        guard let timestamp = lastANEUpdateAt else {
            return nil
        }
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
        DispatchQueue.global(qos: .utility).async {
            let catalog = discoverModelCatalog(in: root)
            DispatchQueue.main.async { [weak self] in
                self?.applyModelCatalog(catalog, force: force)
                self?.modelRefreshInFlight = false
            }
        }
    }

    private func applyModelCatalog(_ catalog: ModelCatalog, force: Bool) {
        let previousPaths = Set(lastModelCatalog?.artifacts.map(\.relativePath) ?? [])
        let currentPaths = Set(catalog.artifacts.map(\.relativePath))
        let added = currentPaths.subtracting(previousPaths)
        let removed = previousPaths.subtracting(currentPaths)
        let health = modelHealthSummary(catalog: catalog, repoRoot: repoRoot)

        modelSummaryItem.title = "Models: \(catalog.totalCount) files | \(formatBytes(catalog.totalSizeBytes))"

        if lastModelCatalog == nil {
            modelDeltaItem.title = "Model delta: baseline scan"
        } else {
            modelDeltaItem.title = "Model delta: +\(added.count) / -\(removed.count)"
            if !force, (added.count > 0 || removed.count > 0) {
                statusLineItem.title = "Status: model catalog changed (+\(added.count) -\(removed.count))"
            }
        }

        var lines: [String] = []

        let families = catalog.extensionCounts.prefix(3).map { "\($0.0):\($0.1)" }.joined(separator: ", ")
        lines.append(families.isEmpty ? "Families: none" : "Families: \(families)")
        let bucketLine = health.sizeBucketCounts
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ", ")
        lines.append(bucketLine.isEmpty ? "Sizes: n/a" : "Sizes: \(bucketLine)")
        lines.append("New: 24h \(health.new24h) | 7d \(health.new7d)")
        lines.append("Health: missing tokenizer \(health.missingTokenizer), config \(health.missingConfig)")

        if !added.isEmpty {
            let addedPreview = added.sorted().prefix(2).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            lines.append("Added: \(addedPreview)")
        } else {
            lines.append("Added: none")
        }

        let newest = catalog.newest(limit: 3)
        if newest.isEmpty {
            lines.append("Newest: none")
        } else {
            for artifact in newest {
                lines.append("Newest: \(URL(fileURLWithPath: artifact.relativePath).lastPathComponent)")
            }
        }

        for index in 0..<modelDetailItems.count {
            let item = modelDetailItems[index]
            if index < lines.count {
                item.title = truncate(lines[index], maxLength: 72)
                item.isHidden = compactLayout
            } else {
                item.title = ""
                item.isHidden = true
            }
        }

        lastModelCatalog = catalog
        applyMenuDensity()
    }

    private func refreshUpstreamInfo(force: Bool) {
        if upstreamRefreshInFlight {
            return
        }

        upstreamRefreshInFlight = true
        let root = repoRoot
        DispatchQueue.global(qos: .utility).async {
            if force {
                _ = runShellCommand("git -C \(shellQuote(root)) fetch --quiet origin main")
            }
            let head = readGitHeadInfo(in: root)
            let dirty = readGitDirty(in: root)
            let sync = readGitAheadBehind(in: root)
            DispatchQueue.main.async { [weak self] in
                self?.applyUpstreamInfo(head: head, dirty: dirty, sync: sync, force: force)
                self?.upstreamRefreshInFlight = false
            }
        }
    }

    private func applyUpstreamInfo(head: GitHeadInfo?, dirty: Bool, sync: (ahead: Int, behind: Int)?, force: Bool) {
        guard let head else {
            upstreamHeadItem.title = "HEAD: unavailable"
            upstreamMetaItem.title = "Repo status: not a git repository"
            upstreamSyncItem.title = "Sync: unavailable"
            applyMenuDensity()
            return
        }

        upstreamHeadItem.title = "HEAD: \(head.shortSHA) \(truncate(head.subject, maxLength: 40))"

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short
        let ageText = relativeFormatter.localizedString(for: head.timestamp, relativeTo: Date())
        upstreamMetaItem.title = "Repo: \(dirty ? "dirty" : "clean") | \(ageText)"
        if let sync {
            upstreamSyncItem.title = "Sync: ahead \(sync.ahead) | behind \(sync.behind)"
        } else {
            upstreamSyncItem.title = "Sync: no remote info"
        }

        if let lastSeenRepoSHA, lastSeenRepoSHA != head.shortSHA, !force {
            statusLineItem.title = "Status: repo head changed to \(head.shortSHA)"
        }
        lastSeenRepoSHA = head.shortSHA
        applyMenuDensity()
    }

    private func runDueQueueIfNeeded() {
        guard process == nil else {
            return
        }
        guard let next = queueStore.duePending() else {
            return
        }

        let resolvedExperiment: ExperimentDefinition?
        if let experimentID = next.experimentID {
            if experimentID.hasPrefix("preset."),
               let preset = RunPreset(rawValue: String(experimentID.dropFirst("preset.".count))) {
                resolvedExperiment = experiment(for: preset)
            } else {
                resolvedExperiment = experimentByID(experimentID)
            }
        } else if let preset = RunPreset(rawValue: next.preset) {
            resolvedExperiment = experiment(for: preset)
        } else {
            resolvedExperiment = nil
        }

        guard let experiment = resolvedExperiment else {
            queueStore.markFinished(id: next.id, exitCode: 1)
            refreshQueueSummary()
            return
        }
        if let reason = guardrailBlockReason(for: experiment) {
            queueSummaryItem.title = "Queue blocked: \(reason)"
            return
        }
        queueStore.markRunning(id: next.id)
        refreshQueueSummary()
        runExperiment(experiment, queueItemID: next.id)
    }

    private func refreshQueueSummary() {
        let pending = queueStore.items.filter { $0.state == "pending" }
        if pending.isEmpty {
            queueSummaryItem.title = "Queue: 0 pending"
            return
        }
        let sorted = pending.sorted { $0.scheduledAt < $1.scheduledAt }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let nextLabel = formatter.localizedString(for: sorted[0].scheduledAt, relativeTo: Date())
        let nextTitle = sorted[0].title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nextTitle, !nextTitle.isEmpty {
            queueSummaryItem.title = "Queue: \(pending.count) pending | \(nextTitle) \(nextLabel)"
        } else {
            queueSummaryItem.title = "Queue: \(pending.count) pending | next \(nextLabel)"
        }
    }

    private func refreshGuardrailLine() {
        let battery = readBatteryStatus()
        let thermal = ProcessInfo.processInfo.thermalState
        let batteryText: String
        if let percent = battery.percent {
            batteryText = "\(percent)%\(battery.isCharging ? " charging" : " battery")"
        } else {
            batteryText = "unknown battery"
        }
        guardrailItem.title = "Guardrails: \(batteryText) | thermal \(thermalLabel(thermal))"
    }

    @objc private func exportReproBundle() {
        let base = historyStore.baseDirectory.appendingPathComponent("exports", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let outDir = base.appendingPathComponent("run-\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            statusLineItem.title = "Status: export failed (mkdir)"
            return
        }

        let latestRun = historyStore.recent(limit: 1).first
        let summaryFile = writeBenchmarkSummaryFile()
        let metadata: [String: Any] = [
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "repo_root": repoRoot,
            "repo_head": lastSeenRepoSHA as Any,
            "latest_run": [
                "id": latestRun?.id as Any,
                "mode": latestRun?.mode as Any,
                "exit_code": latestRun?.exitCode as Any,
                "duration_seconds": latestRun?.durationSeconds as Any,
                "ane_tflops": latestRun?.aneTFLOPS as Any,
                "ane_utilization": latestRun?.aneUtilization as Any,
                "avg_train_ms": latestRun?.avgTrainMS as Any,
            ],
            "queue_pending": queueStore.pendingCount(),
            "history_file": historyStore.fileURL.path,
            "benchmark_summary_file": summaryFile.path,
        ]

        let metadataURL = outDir.appendingPathComponent("metadata.json")
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: metadataURL, options: .atomic)
        }

        let notes = """
        # ANEbar Repro Bundle

        - Exported: \(ISO8601DateFormatter().string(from: Date()))
        - Repo: \(repoRoot)
        - HEAD: \(lastSeenRepoSHA ?? "unknown")
        - Run history: \(historyStore.fileURL.path)
        - Benchmark summary: \(summaryFile.path)
        """
        try? notes.write(to: outDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        NSWorkspace.shared.open(outDir)
        statusLineItem.title = "Status: exported repro bundle"
        reopenMenuIfNeeded()
    }

    @objc private func openBenchmarkSummary() {
        let url = writeBenchmarkSummaryFile()
        NSWorkspace.shared.open(url)
        reopenMenuIfNeeded()
    }

    private func writeBenchmarkSummaryFile() -> URL {
        let url = historyStore.baseDirectory.appendingPathComponent("benchmark_summary.md")
        var lines: [String] = []
        lines.append("# ANEbar Benchmark Summary")
        lines.append("")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        let runs = historyStore.records.filter { $0.exitCode == 0 }
        if runs.isEmpty {
            lines.append("No successful runs yet.")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let bestTFLOPS = runs.compactMap(\.aneTFLOPS).max()
        let bestUtil = runs.compactMap(\.aneUtilization).max()
        let bestLatency = runs.compactMap(\.avgTrainMS).min()

        lines.append("- Successful runs: \(runs.count)")
        lines.append(bestTFLOPS != nil ? String(format: "- Best ANE TFLOPS: %.2f", bestTFLOPS!) : "- Best ANE TFLOPS: n/a")
        lines.append(bestUtil != nil ? String(format: "- Best Utilization: %.2f%%", bestUtil!) : "- Best Utilization: n/a")
        lines.append(bestLatency != nil ? String(format: "- Best Avg Train: %.2fms", bestLatency!) : "- Best Avg Train: n/a")
        lines.append("")
        lines.append("| Ended | Mode | Head | ANE TFLOPS | Util % | Avg ms | Telemetry |")
        lines.append("|---|---|---|---:|---:|---:|---|")

        let formatter = ISO8601DateFormatter()
        for run in runs.suffix(20) {
            let ended = formatter.string(from: run.endedAt)
            let tflops = run.aneTFLOPS.map { String(format: "%.2f", $0) } ?? "-"
            let util = run.aneUtilization.map { String(format: "%.2f", $0) } ?? "-"
            let avg = run.avgTrainMS.map { String(format: "%.2f", $0) } ?? "-"
            let head = run.repoHead ?? "-"
            let mode = run.title ?? run.mode
            let telemetry = run.telemetrySource ?? "-"
            lines.append("| \(ended) | \(mode) | \(head) | \(tflops) | \(util) | \(avg) | \(telemetry) |")
        }

        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func refreshRunHistoryLines() {
        let recent = historyStore.recent(limit: 2)
        historyWindowController?.update(records: historyStore.recentDescending(limit: 120), repoRoot: repoRoot)
        historyWindowController?.setBusy(process != nil)
        guard let latest = recent.last else {
            historySummaryItem.title = "Run history: none"
            historyDetailItem.title = "Last metrics: n/a"
            historyDeltaItem.title = "Comparison: n/a"
            applyMenuDensity()
            return
        }

        let outcome = latest.exitCode == 0 ? "ok" : "failed(\(latest.exitCode))"
        let latestLabel = latest.title ?? latest.mode
        historySummaryItem.title = "Last run: \(latestLabel) | \(outcome) | \(formatDuration(latest.durationSeconds))"

        var metricParts: [String] = []
        if let tflops = latest.aneTFLOPS {
            metricParts.append(String(format: "ANE %.2fT", tflops))
        }
        if let util = latest.aneUtilization {
            metricParts.append(String(format: "Util %.1f%%", util))
        }
        if let avgTrainMS = latest.avgTrainMS {
            metricParts.append(String(format: "Avg %.1fms", avgTrainMS))
        }
        historyDetailItem.title = metricParts.isEmpty ? "Last metrics: n/a" : "Last metrics: \(metricParts.joined(separator: " | "))"

        guard recent.count == 2 else {
            historyDeltaItem.title = "Comparison: waiting for second run"
            return
        }

        let previous = recent[0]
        var deltas: [String] = []
        if let last = latest.aneTFLOPS, let prev = previous.aneTFLOPS {
            deltas.append("ANE " + formatSigned(last - prev, suffix: "T"))
        }
        if let last = latest.aneUtilization, let prev = previous.aneUtilization {
            deltas.append("Util " + formatSigned(last - prev, suffix: "%"))
        }
        if let last = latest.avgTrainMS, let prev = previous.avgTrainMS {
            deltas.append("Avg " + formatSigned(last - prev, suffix: "ms"))
        }

        historyDeltaItem.title = deltas.isEmpty ? "Comparison: n/a" : "Comparison: \(deltas.joined(separator: " | "))"
        applyMenuDensity()
    }

    private func hydrateMetricsFromResearchArtifactsIfNeeded(command: String) {
        guard command.contains("run_research.py"),
              let summary = parseResearchSummary(in: repoRoot)
        else {
            return
        }

        if currentRunAneTFLOPS == nil {
            currentRunAneTFLOPS = summary.aneTFLOPS
        }
        if currentRunAneUtilization == nil {
            currentRunAneUtilization = summary.aneUtilization
        }
        if currentRunAvgTrainMS == nil {
            currentRunAvgTrainMS = summary.avgStepMS
        }
        setTelemetrySource("artifact report")
    }

    private func applyCapturedOutputMetricsIfNeeded(experimentID: String?, output: String) {
        guard let experimentID else {
            return
        }

        switch experimentID {
        case "inmem_peak", "inmem_bench", "sram_bench", "sram_probe":
            guard currentRunAneTFLOPS == nil, let bestTFLOPS = parseBestTFLOPSFromTable(output) else {
                return
            }
            currentRunAneTFLOPS = bestTFLOPS
            let peak = configuredPeakTFLOPS()
            currentRunAneUtilization = peak > 0 ? (bestTFLOPS / peak) * 100.0 : nil
            setTelemetrySource("benchmark summary")
        case "test_qos_sweep":
            guard let summary = parseQosSweepSummary(output) else {
                return
            }
            if currentRunAneTFLOPS == nil {
                currentRunAneTFLOPS = summary.aneTFLOPS
            }
            if currentRunAneUtilization == nil {
                currentRunAneUtilization = summary.aneUtilization
            }
            if currentRunAvgTrainMS == nil {
                currentRunAvgTrainMS = summary.avgStepMS
            }
            setTelemetrySource("probe summary")
        default:
            break
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
