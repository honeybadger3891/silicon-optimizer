import Foundation
import SiliconControl
import SiliconRuntime

/// The Settings-pane face of `OpenMontageLink`: one button that downloads OpenMontage,
/// installs what it needs, drops this app in as a provider, and one more that opens it
/// in the Chat tab with Codex already sitting in the checkout.
extension AppModel {

    var openMontageEnvironment: OpenMontageLink.Environment {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser

        var source: URL?
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("openmontage"),
           files.fileExists(atPath: bundled.appendingPathComponent("VERSION").path) {
            source = bundled
        }

        // Every interpreter in the usual places; the link picks among them by wheel
        // coverage, not recency, so all of them are offered.
        var pythons: [URL] = []
        // The python.org installer puts each version under its own Framework directory and
        // only sometimes symlinks it into /usr/local/bin; look in both.
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                           home.appendingPathComponent(".pyenv/shims").path]
        for version in ["3.12", "3.11", "3.13", "3.10"] {
            directories.append("/Library/Frameworks/Python.framework/Versions/\(version)/bin")
        }
        for directory in directories {
            for name in ["python3.12", "python3.11", "python3.13", "python3.10", "python3"] {
                let candidate = URL(fileURLWithPath: "\(directory)/\(name)")
                if files.isExecutableFile(atPath: candidate.path) { pythons.append(candidate) }
            }
        }

        let git = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .map { URL(fileURLWithPath: $0) }
            .first { files.isExecutableFile(atPath: $0.path) }

        // npm beside the Node this app already trusts, then the usual places.
        var npmCandidates: [URL] = []
        if let node = HarnessRuntime.locateNode(customPath: settings.nodeBinaryPath ?? "").node {
            npmCandidates.append(node.deletingLastPathComponent().appendingPathComponent("npm"))
        }
        npmCandidates += ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].map { URL(fileURLWithPath: $0) }
        let npm = npmCandidates.first { files.isExecutableFile(atPath: $0.path) }

        return OpenMontageLink.Environment(
            home: home,
            providerSource: source,
            npm: npm,
            pythons: pythons,
            git: git
        )
    }

    public func refreshOpenMontage() {
        openMontageStatus = OpenMontageLink.detect(in: openMontageEnvironment)
    }

    /// Downloads, installs, links. Long: the Python dependencies alone are a few minutes
    /// the first time, so every step reports itself as it starts and the button stays a
    /// spinner until the last one ends.
    public func setUpOpenMontage() async {
        guard openMontageStage == nil else { return }
        let environment = openMontageEnvironment
        openMontageNote = nil
        defer {
            openMontageStage = nil
            refreshOpenMontage()
        }

        let steps: [OpenMontageLink.Step]
        var notes: [String]
        do {
            (steps, notes) = try OpenMontageLink.plan(in: environment)
        } catch {
            openMontageNote = error.localizedDescription
            return
        }

        for step in steps {
            openMontageStage = step.label
            let result: CommandResult
            do {
                result = try await Self.runStep(step)
            } catch {
                openMontageNote = "\(step.label) could not start: \(error.localizedDescription)"
                return
            }
            guard result.status == 0 else {
                let tail = result.output
                    .split(separator: "\n").suffix(4).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if step.optional {
                    notes.append("\(step.label) — skipped. \(tail)")
                    continue
                }
                openMontageNote = "\(step.label) failed.\n\(tail)"
                return
            }
        }

        openMontageStage = "Linking this app in as a provider"
        do {
            try OpenMontageLink.installProvider(in: environment)
        } catch {
            openMontageNote = error.localizedDescription
            return
        }

        var summary = "Ready. Images, video and 3D from this app now show in "
            + "OpenMontage's catalogue at $0."
        if !notes.isEmpty { summary += "\n" + notes.joined(separator: "\n") }
        openMontageNote = summary
    }

    /// Just the provider, for a checkout that exists — someone cloned it themselves, or
    /// this build carries a newer provider than the one in there.
    public func relinkOpenMontage() {
        do {
            try OpenMontageLink.installProvider(in: openMontageEnvironment)
            openMontageNote = "Provider updated."
        } catch {
            openMontageNote = error.localizedDescription
        }
        refreshOpenMontage()
    }

    /// Codex, sitting in the checkout, in the Chat tab. OpenMontage's own instructions
    /// tell the agent everything else.
    public func openOpenMontageInChat() {
        let checkout = OpenMontageLink.checkoutURL(in: openMontageEnvironment)
        settings.codexWorkingDirectory = checkout.path
        settings.chatEngine = .codex
        settings.save()
        chatEngineDidChange()
        // A Codex already running was started somewhere else; it needs to come back up here.
        if case .ready = codexState { restartCodex() }
        selectedTab = .chat
    }

    // MARK: - Running a step

    struct CommandResult: Sendable {
        let status: Int32
        let output: String
    }

    private static func runStep(_ step: OpenMontageLink.Step) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = step.executable
            process.arguments = step.arguments
            process.currentDirectoryURL = step.workingDirectory
            // pip and npm both read PATH for helpers; give them the step's own bin first.
            var environment = ProcessInfo.processInfo.environment
            let bin = step.executable.deletingLastPathComponent().path
            environment["PATH"] = "\(bin):/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: CommandResult(
                    status: finished.terminationStatus,
                    output: String(data: data, encoding: .utf8) ?? ""
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // A wedged pip must not pin the button forever. Twenty minutes covers a cold
            // dependency install on a slow connection with room to spare.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1200) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
