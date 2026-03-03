import AppKit
import Foundation

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
    private var process: Process?
    private var lastExitCode: Int32?

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

        statusLineItem = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        repoLineItem = NSMenuItem(title: "Repo: \(repoRoot)", action: nil, keyEquivalent: "")
        repoLineItem.isEnabled = false
        menu.addItem(repoLineItem)
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
    }

    private func setRunning(_ running: Bool, message: String) {
        runFastItem.isEnabled = !running
        runFullItem.isEnabled = !running
        statusLineItem.title = "Status: \(message)"
        statusItem.button?.title = running ? "ANE…" : "ANE"
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

        setRunning(true, message: skipBuild ? "running fast pipeline" : "running full pipeline")
        process = proc

        proc.terminationHandler = { [weak self] finished in
            Task { @MainActor in
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
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
