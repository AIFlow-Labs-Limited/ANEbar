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
    var command: String
    var repoRoot: String
    var repoHead: String?
    var startedAt: Date
    var endedAt: Date
    var durationSeconds: Double
    var exitCode: Int32
    var aneUtilization: Double?
    var aneTFLOPS: Double?
    var totalTFLOPS: Double?
    var avgTrainMS: Double?
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
        let now = Date()
        let item = QueueItem(
            id: UUID().uuidString,
            preset: preset.rawValue,
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

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func runShellCommand(_ command: String) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]

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
    let text = String(data: data, encoding: .utf8) ?? ""
    return (status: process.terminationStatus, output: text)
}

private func readGitHeadInfo(in repoRoot: String) -> GitHeadInfo? {
    let quoted = shellQuote(repoRoot)
    let command = "git -C \(quoted) log -1 --pretty=%h\\|%ct\\|%s"
    let result = runShellCommand(command)
    guard result.status == 0 else {
        return nil
    }
    let line = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let tokens = result.output
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

@MainActor
private final class ChatWindowController: NSWindowController {
    private enum DefaultsKey {
        static let chatModel = "anebar_chat_model"
    }

    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let promptField = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh Models", target: nil, action: nil)
    private let pullSmallModelButton = NSButton(title: "Pull qwen2.5:0.5b", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Local chat ready")
    private let outputTextView = NSTextView(frame: .zero)

    private var chatProcess: Process?
    private var fallbackModels: [String] = []
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
        window.title = "ANEbar Local Chat"
        window.minSize = NSSize(width: 560, height: 420)
        super.init(window: window)
        setupUI()
        reloadModels(preserveSelection: true)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setFallbackModels(_ models: [String]) {
        fallbackModels = Array(Set(models)).sorted()
        if modelPopup.numberOfItems == 0 {
            reloadModels(preserveSelection: true)
        }
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let titleLabel = NSTextField(labelWithString: "Model")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
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

        pullSmallModelButton.target = self
        pullSmallModelButton.action = #selector(pullSmallModel)

        clearButton.target = self
        clearButton.action = #selector(clearOutput)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.isRichText = false
        outputTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.string = "ANEbar local chat. Select a small model and start chatting.\n"
        outputTextView.textColor = .labelColor
        outputTextView.backgroundColor = .textBackgroundColor

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.documentView = outputTextView

        let controlsStack = NSStackView(views: [
            titleLabel, modelPopup, refreshButton, pullSmallModelButton, stopButton, clearButton,
        ])
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

        let root = NSStackView(views: [controlsStack, promptStack, scrollView, statusLabel])
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

    private func discoverOllamaModels() -> [String] {
        let result = runShellCommand("ollama list")
        guard result.status == 0 else {
            return []
        }
        let rows = result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .dropFirst()
        var models: [String] = []
        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            if let first = parts.first {
                models.append(String(first))
            }
        }
        return Array(Set(models)).sorted()
    }

    @objc private func refreshModels() {
        reloadModels(preserveSelection: true)
    }

    private func reloadModels(preserveSelection: Bool) {
        let previous = preserveSelection ? modelPopup.titleOfSelectedItem : nil
        let discovered = discoverOllamaModels()
        let defaults = ["qwen2.5:0.5b", "qwen2.5:1.5b", "phi3:mini", "llama3.2:1b"]
        let merged = discovered.isEmpty ? Array(Set(defaults + fallbackModels)).sorted() : discovered

        modelPopup.removeAllItems()
        if merged.isEmpty {
            statusLabel.stringValue = "No models discovered. Install Ollama and pull a small model."
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

        if discovered.isEmpty {
            statusLabel.stringValue = "No local Ollama model found. Pull one (e.g. ollama pull qwen2.5:0.5b)."
        } else {
            statusLabel.stringValue = "Ready. Streaming from local Ollama runtime."
        }
    }

    @objc private func clearOutput() {
        outputTextView.string = ""
    }

    @objc private func pullSmallModel() {
        guard chatProcess == nil else {
            statusLabel.stringValue = "Stop current chat before pulling."
            return
        }
        statusLabel.stringValue = "Pulling qwen2.5:0.5b..."
        appendOutput("\n[pull] ollama pull qwen2.5:0.5b\n")
        let result = runShellCommand("ollama pull qwen2.5:0.5b")
        if !result.output.isEmpty {
            appendOutput(result.output + "\n")
        }
        if result.status == 0 {
            statusLabel.stringValue = "Model pulled. Refreshing list..."
            reloadModels(preserveSelection: true)
        } else {
            statusLabel.stringValue = "Pull failed. Check Ollama service."
        }
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

        UserDefaults.standard.set(model, forKey: DefaultsKey.chatModel)
        promptField.stringValue = ""

        appendOutput("\nYou: \(prompt)\nAssistant: ")
        streamStartedAt = Date()
        streamTokenApproxCount = 0

        let command = "ollama run \(shellQuote(model)) \(shellQuote(prompt))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]

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
                    self?.statusLabel.stringValue = "Chat command failed (\(proc.terminationStatus))."
                    self?.appendOutput("\n\n[chat failed]\n")
                }
            }
        }

        do {
            try process.run()
            chatProcess = process
            sendButton.isEnabled = false
            stopButton.isEnabled = true
            statusLabel.stringValue = "Streaming response..."
        } catch {
            chatProcess = nil
            statusLabel.stringValue = "Could not launch ollama. Is it installed/running?"
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
    private let maxPoints = 120

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
        guard let latest = history.last else {
            return
        }

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
        drawProgressRow(
            label: "ANE(run)",
            valueText: aneValue.map(percentText) ?? "n/a",
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
        color.withAlphaComponent(dimmed ? 0.25 : 0.95).setFill()
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
        path.lineWidth = 1.7
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

    private var statusLineItem = NSMenuItem()
    private var repoLineItem = NSMenuItem()
    private var guardrailItem = NSMenuItem()

    private var upstreamHeadItem = NSMenuItem()
    private var upstreamMetaItem = NSMenuItem()
    private var upstreamSyncItem = NSMenuItem()

    private var modelSummaryItem = NSMenuItem()
    private var modelDeltaItem = NSMenuItem()
    private var modelDetailItems: [NSMenuItem] = []

    private var historySummaryItem = NSMenuItem()
    private var historyDetailItem = NSMenuItem()
    private var historyDeltaItem = NSMenuItem()

    private var metricsView = LiveMetricsMenuView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
    private var chatWindowController: ChatWindowController?

    private let historyStore = RunHistoryStore()
    private let queueStore = RunQueueStore(baseDirectory: anebarDataDirectory())

    private var process: Process?
    private var activeQueueItemID: String?
    private var runStartedAt: Date?
    private var currentRunPreset: RunPreset?
    private var currentRunCommand: String?
    private var currentRunAneUtilization: Double?
    private var currentRunAneTFLOPS: Double?
    private var currentRunTotalTFLOPS: Double?
    private var currentRunAvgTrainMS: Double?

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
        refreshRunHistoryLines()
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

        guardrailItem = NSMenuItem(title: "Guardrails: checking…", action: nil, keyEquivalent: "")
        guardrailItem.isEnabled = false
        menu.addItem(guardrailItem)

        upstreamHeadItem = NSMenuItem(title: "HEAD: scanning…", action: nil, keyEquivalent: "")
        upstreamHeadItem.isEnabled = false
        menu.addItem(upstreamHeadItem)

        upstreamMetaItem = NSMenuItem(title: "Repo status: unknown", action: nil, keyEquivalent: "")
        upstreamMetaItem.isEnabled = false
        menu.addItem(upstreamMetaItem)

        upstreamSyncItem = NSMenuItem(title: "Sync: unknown", action: nil, keyEquivalent: "")
        upstreamSyncItem.isEnabled = false
        menu.addItem(upstreamSyncItem)

        let refreshUpstreamItem = NSMenuItem(title: "Refresh Repo Head", action: #selector(refreshUpstreamManual), keyEquivalent: "u")
        refreshUpstreamItem.target = self
        menu.addItem(refreshUpstreamItem)

        menu.addItem(.separator())

        modelSummaryItem = NSMenuItem(title: "Models: scanning…", action: nil, keyEquivalent: "")
        modelSummaryItem.isEnabled = false
        menu.addItem(modelSummaryItem)

        modelDeltaItem = NSMenuItem(title: "Model delta: baseline", action: nil, keyEquivalent: "")
        modelDeltaItem.isEnabled = false
        menu.addItem(modelDeltaItem)

        for _ in 0..<6 {
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

        runFastItem = NSMenuItem(title: RunPreset.fast.menuTitle, action: #selector(runFastPipeline), keyEquivalent: "r")
        runFastItem.target = self
        menu.addItem(runFastItem)

        runFullItem = NSMenuItem(title: RunPreset.full.menuTitle, action: #selector(runFullPipeline), keyEquivalent: "R")
        runFullItem.target = self
        menu.addItem(runFullItem)

        runBenchmarkItem = NSMenuItem(title: RunPreset.benchmark.menuTitle, action: #selector(runBenchmarkPipeline), keyEquivalent: "b")
        runBenchmarkItem.target = self
        menu.addItem(runBenchmarkItem)

        queueFastItem = NSMenuItem(title: "Queue Fast", action: #selector(queueFastRun), keyEquivalent: "")
        queueFastItem.target = self
        menu.addItem(queueFastItem)

        queueFullItem = NSMenuItem(title: "Queue Full", action: #selector(queueFullRun), keyEquivalent: "")
        queueFullItem.target = self
        menu.addItem(queueFullItem)

        queueBenchmarkItem = NSMenuItem(title: "Queue Benchmark (+10m)", action: #selector(queueBenchmarkRunDelayed), keyEquivalent: "")
        queueBenchmarkItem.target = self
        menu.addItem(queueBenchmarkItem)

        queueSummaryItem = NSMenuItem(title: "Queue: 0 pending", action: nil, keyEquivalent: "")
        queueSummaryItem.isEnabled = false
        menu.addItem(queueSummaryItem)

        let clearQueueItem = NSMenuItem(title: "Clear Pending Queue", action: #selector(clearPendingQueue), keyEquivalent: "")
        clearQueueItem.target = self
        menu.addItem(clearQueueItem)

        let openChatItem = NSMenuItem(title: "Open Local Chat", action: #selector(openLocalChat), keyEquivalent: "l")
        openChatItem.target = self
        menu.addItem(openChatItem)

        let stopItem = NSMenuItem(title: "Stop Running Job", action: #selector(stopJob), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        historySummaryItem = NSMenuItem(title: "Run history: none", action: nil, keyEquivalent: "")
        historySummaryItem.isEnabled = false
        menu.addItem(historySummaryItem)

        historyDetailItem = NSMenuItem(title: "Last metrics: n/a", action: nil, keyEquivalent: "")
        historyDetailItem.isEnabled = false
        menu.addItem(historyDetailItem)

        historyDeltaItem = NSMenuItem(title: "Comparison: n/a", action: nil, keyEquivalent: "")
        historyDeltaItem.isEnabled = false
        menu.addItem(historyDeltaItem)

        let openHistoryItem = NSMenuItem(title: "Open Run History JSON", action: #selector(openRunHistoryFile), keyEquivalent: "j")
        openHistoryItem.target = self
        menu.addItem(openHistoryItem)

        let exportBundleItem = NSMenuItem(title: "Export Repro Bundle", action: #selector(exportReproBundle), keyEquivalent: "e")
        exportBundleItem.target = self
        menu.addItem(exportBundleItem)

        let openBenchmarkSummaryItem = NSMenuItem(title: "Open Benchmark Summary", action: #selector(openBenchmarkSummary), keyEquivalent: "k")
        openBenchmarkSummaryItem.target = self
        menu.addItem(openBenchmarkSummaryItem)

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
        refreshGuardrailLine()
        refreshModelIndex(force: true)
        refreshUpstreamInfo(force: true)
        refreshQueueSummary()
        refreshRunHistoryLines()
    }

    private func setRunning(_ running: Bool, message: String) {
        runFastItem.isEnabled = !running
        runFullItem.isEnabled = !running
        runBenchmarkItem.isEnabled = !running
        queueFastItem.isEnabled = !running
        queueFullItem.isEnabled = !running
        queueBenchmarkItem.isEnabled = !running
        statusLineItem.title = "Status: \(message)"
        updateStatusButton()
    }

    private func command(for preset: RunPreset) -> String? {
        let fileManager = FileManager.default
        let researchScript = "\(repoRoot)/training/research/run_research.py"
        if fileManager.fileExists(atPath: researchScript) {
            switch preset {
            case .fast:
                return "uv run python training/research/run_research.py --qos-runs 2 --skip-build"
            case .full:
                return "uv run python training/research/run_research.py --qos-runs 3"
            case .benchmark:
                return "uv run python training/research/run_research.py --qos-runs 5"
            }
        }

        let makefile = "\(repoRoot)/training/Makefile"
        let hasMakefile = fileManager.fileExists(atPath: makefile)
        if hasMakefile {
            let aneTargetPath = "\(repoRoot)/training/train_large_ane.m"
            let standardTargetPath = "\(repoRoot)/training/train_large.m"
            let target: String
            if fileManager.fileExists(atPath: aneTargetPath) {
                target = "train_large_ane"
            } else if fileManager.fileExists(atPath: standardTargetPath) {
                target = "train_large"
            } else {
                return nil
            }

            let steps: Int
            switch preset {
            case .fast:
                steps = 40
            case .full:
                steps = 200
            case .benchmark:
                steps = 100
            }

            return "make -C training \(target) && ./training/\(target) --steps \(steps)"
        }

        return nil
    }

    private func runPreset(_ preset: RunPreset, queueItemID: String? = nil) {
        guard process == nil else {
            return
        }

        guard let command = command(for: preset) else {
            statusLineItem.title = "Status: no matching run command for repo"
            return
        }

        if let guardrailMessage = guardrailBlockReason(for: preset) {
            statusLineItem.title = "Status: blocked by guardrail (\(guardrailMessage))"
            refreshGuardrailLine()
            return
        }

        currentRunPreset = preset
        currentRunCommand = command
        currentRunAneUtilization = nil
        currentRunAneTFLOPS = nil
        currentRunTotalTFLOPS = nil
        currentRunAvgTrainMS = nil
        runStartedAt = Date()
        activeQueueItemID = queueItemID

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

        setRunning(true, message: "running \(preset.displayTitle) preset")
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

    private func persistRunResult(exitCode: Int32) {
        guard let preset = currentRunPreset,
              let command = currentRunCommand,
              let startedAt = runStartedAt
        else {
            currentRunPreset = nil
            currentRunCommand = nil
            runStartedAt = nil
            return
        }

        hydrateMetricsFromResearchArtifactsIfNeeded(command: command)

        let endedAt = Date()
        let duration = endedAt.timeIntervalSince(startedAt)

        let record = RunRecord(
            id: UUID().uuidString,
            mode: preset.rawValue,
            command: command,
            repoRoot: repoRoot,
            repoHead: lastSeenRepoSHA,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: duration,
            exitCode: exitCode,
            aneUtilization: currentRunAneUtilization,
            aneTFLOPS: currentRunAneTFLOPS,
            totalTFLOPS: currentRunTotalTFLOPS,
            avgTrainMS: currentRunAvgTrainMS
        )

        historyStore.append(record)
        if let activeQueueItemID {
            queueStore.markFinished(id: activeQueueItemID, exitCode: exitCode)
        }
        _ = writeBenchmarkSummaryFile()
        refreshRunHistoryLines()
        refreshQueueSummary()

        currentRunPreset = nil
        currentRunCommand = nil
        runStartedAt = nil
        activeQueueItemID = nil
    }

    @objc private func runFastPipeline() {
        runPreset(.fast)
    }

    @objc private func runFullPipeline() {
        runPreset(.full)
    }

    @objc private func runBenchmarkPipeline() {
        runPreset(.benchmark)
    }

    @objc private func queueFastRun() {
        _ = queueStore.enqueue(preset: .fast)
        refreshQueueSummary()
        statusLineItem.title = "Status: queued fast preset"
    }

    @objc private func queueFullRun() {
        _ = queueStore.enqueue(preset: .full)
        refreshQueueSummary()
        statusLineItem.title = "Status: queued full preset"
    }

    @objc private func queueBenchmarkRunDelayed() {
        _ = queueStore.enqueue(preset: .benchmark, delaySeconds: 10 * 60)
        refreshQueueSummary()
        statusLineItem.title = "Status: queued benchmark (+10m)"
    }

    @objc private func clearPendingQueue() {
        queueStore.cancelAllPending()
        refreshQueueSummary()
        statusLineItem.title = "Status: cleared pending queue"
    }

    @objc private func openLocalChat() {
        if chatWindowController == nil {
            chatWindowController = ChatWindowController()
        }
        let fallbackModels = lastModelCatalog?.artifacts
            .prefix(8)
            .map { URL(fileURLWithPath: $0.relativePath).deletingPathExtension().lastPathComponent } ?? []
        chatWindowController?.setFallbackModels(fallbackModels)
        chatWindowController?.showWindow(nil)
        chatWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func stopJob() {
        process?.terminate()
    }

    @objc private func openResultsFolder() {
        let candidates = [
            "\(repoRoot)/training/research/results",
            "\(repoRoot)/training",
            repoRoot,
        ]
        openFirstExistingPath(candidates)
    }

    @objc private func openHeroGraphic() {
        let candidates = [
            "\(repoRoot)/training/research/results/figures/ane_hero_card_instagram.png",
            "\(repoRoot)/training/dashboard.gif",
            "\(repoRoot)/README.md",
        ]
        openFirstExistingPath(candidates)
    }

    @objc private func openSpotlightGraphic() {
        let candidates = [
            "\(repoRoot)/training/research/results/figures/ecosystem_spotlight_card_instagram.png",
            "\(repoRoot)/training/m5result.md",
            "\(repoRoot)/README.md",
        ]
        openFirstExistingPath(candidates)
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
                return
            }
        }

        statusLineItem.title = "Status: could not find post draft"
    }

    @objc private func openRunHistoryFile() {
        NSWorkspace.shared.open(historyStore.fileURL)
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
    }

    @objc private func refreshUpstreamManual() {
        refreshUpstreamInfo(force: true)
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
        if metricsTick % 5 == 0, let command = currentRunCommand {
            hydrateMetricsFromResearchArtifactsIfNeeded(command: command)
        }
        runDueQueueIfNeeded()

        guard let cpu = metricsSampler.sampleCPU() else {
            return
        }

        let sample = LiveMetricsSample(
            timestamp: Date(),
            totalCPUUsage: cpu.total,
            pCoreUsage: cpu.pCores,
            eCoreUsage: cpu.eCores,
            memoryUsage: metricsSampler.sampleMemoryPercent(),
            load1m: metricsSampler.sampleLoadAverage1m(),
            aneUtilization: activeANEUtilization(),
            aneTFLOPS: activeANETflops(),
            runActive: process != nil
        )

        latestMetrics = sample
        metricsView.push(sample)
        refreshGuardrailLine()
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
        if let utilization = captureDouble(in: line, pattern: #"ANE utilization:\s*([0-9]+(?:\.[0-9]+)?)%"#) {
            lastANEUtilization = utilization
            currentRunAneUtilization = utilization
            lastANEUpdateAt = Date()
        }

        if let aneTFLOPS = captureDouble(in: line, pattern: #"ANE TFLOPS:\s*([0-9]+(?:\.[0-9]+)?)"#) {
            lastANETflops = aneTFLOPS
            currentRunAneTFLOPS = aneTFLOPS
            lastANEUpdateAt = Date()
        }

        if let totalTFLOPS = captureDouble(in: line, pattern: #"Total TFLOPS:\s*([0-9]+(?:\.[0-9]+)?)"#) {
            currentRunTotalTFLOPS = totalTFLOPS
        }

        if let avgTrainMS = captureDouble(in: line, pattern: #"Avg train:\s*([0-9]+(?:\.[0-9]+)?)\s*ms/step"#) {
            currentRunAvgTrainMS = avgTrainMS
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
                item.isHidden = false
            } else {
                item.title = ""
                item.isHidden = true
            }
        }

        lastModelCatalog = catalog
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
            return
        }

        upstreamHeadItem.title = "HEAD: \(head.shortSHA) \(truncate(head.subject, maxLength: 52))"

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
    }

    private func runDueQueueIfNeeded() {
        guard process == nil else {
            return
        }
        guard let next = queueStore.duePending() else {
            return
        }
        guard let preset = RunPreset(rawValue: next.preset) else {
            queueStore.markFinished(id: next.id, exitCode: 1)
            refreshQueueSummary()
            return
        }
        if let reason = guardrailBlockReason(for: preset) {
            queueSummaryItem.title = "Queue blocked: \(reason)"
            return
        }
        queueStore.markRunning(id: next.id)
        refreshQueueSummary()
        runPreset(preset, queueItemID: next.id)
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
        queueSummaryItem.title = "Queue: \(pending.count) pending | next \(nextLabel)"
    }

    private func guardrailBlockReason(for preset: RunPreset) -> String? {
        if preset == .fast {
            return nil
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
    }

    @objc private func openBenchmarkSummary() {
        let url = writeBenchmarkSummaryFile()
        NSWorkspace.shared.open(url)
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
        lines.append("| Ended | Mode | Head | ANE TFLOPS | Util % | Avg ms |")
        lines.append("|---|---|---|---:|---:|---:|")

        let formatter = ISO8601DateFormatter()
        for run in runs.suffix(20) {
            let ended = formatter.string(from: run.endedAt)
            let tflops = run.aneTFLOPS.map { String(format: "%.2f", $0) } ?? "-"
            let util = run.aneUtilization.map { String(format: "%.2f", $0) } ?? "-"
            let avg = run.avgTrainMS.map { String(format: "%.2f", $0) } ?? "-"
            let head = run.repoHead ?? "-"
            lines.append("| \(ended) | \(run.mode) | \(head) | \(tflops) | \(util) | \(avg) |")
        }

        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func refreshRunHistoryLines() {
        let recent = historyStore.recent(limit: 2)
        guard let latest = recent.last else {
            historySummaryItem.title = "Run history: none"
            historyDetailItem.title = "Last metrics: n/a"
            historyDeltaItem.title = "Comparison: n/a"
            return
        }

        let outcome = latest.exitCode == 0 ? "ok" : "failed(\(latest.exitCode))"
        historySummaryItem.title = "Last run: \(latest.mode) | \(outcome) | \(formatDuration(latest.durationSeconds))"

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

        if let utilization = currentRunAneUtilization {
            lastANEUtilization = utilization
            lastANEUpdateAt = Date()
        }
        if let tflops = currentRunAneTFLOPS {
            lastANETflops = tflops
            lastANEUpdateAt = Date()
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
