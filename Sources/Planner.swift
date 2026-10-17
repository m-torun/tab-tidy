import Foundation

struct PlanItem: Codable {
    let tab: Int
    let category: String
    let reason: String
}

struct Plan {
    let close: [PlanItem]
    let model: String?
    let seconds: Double
}

/// Asks a non-interactive Claude Code session which tabs to close. It runs with
/// the default model and with permission prompts skipped, so it never stops to
/// ask anything.
final class Planner {
    static let timeout: TimeInterval = 600

    static let schema = """
        {"type":"object","additionalProperties":false,"required":["close"],"properties":{"close":{"type":"array",\
        "items":{"type":"object","additionalProperties":false,"required":["tab","category","reason"],"properties":{\
        "tab":{"type":"integer"},\
        "category":{"type":"string","enum":["duplicate","reopenable","login","redirect","empty","done"]},\
        "reason":{"type":"string"}}}}}}
        """

    enum Failure: LocalizedError {
        case claudeNotFound
        case timedOut
        case claude(String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Couldn't find the claude command. Install Claude Code, or tell Tab Tidy where it is with: "
                    + "defaults write \(Bundle.main.bundleIdentifier ?? "") claudePath /path/to/claude"
            case .timedOut:
                return "Claude didn't finish within \(Int(Planner.timeout / 60)) minutes."
            case .claude(let message):
                return message
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var generation = 0

    /// Runs Claude in the background and calls `completion` on the main queue,
    /// unless the run was cancelled first.
    func run(_ tabs: [Chrome.Tab], windowNumbers: [String: Int], completion: @escaping (Result<Plan, Error>) -> Void) {
        cancel()
        let current = lock.withLock { generation }
        let prompt = Self.prompt(tabs, windowNumbers: windowNumbers)
        let started = Date()

        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.lock.withLock { self?.generation == current ? self?.process : nil }?.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> Plan in
                let output = try self.invoke(prompt, generation: current)
                if Date().timeIntervalSince(started) >= Self.timeout { throw Failure.timedOut }
                return try Self.parse(output, tabCount: tabs.count, started: started)
            }
            DispatchQueue.main.async {
                if self.lock.withLock({ self.generation == current }) { completion(result) }
            }
        }
    }

    func cancel() {
        let running = lock.withLock { () -> Process? in
            generation += 1
            defer { process = nil }
            return process
        }
        running?.terminate()
    }

    private func invoke(_ prompt: String, generation current: Int) throws -> Subprocess.Output {
        guard let claude = Self.claudePath() else { throw Failure.claudeNotFound }
        try? Data(prompt.utf8).write(to: Support.file("last-prompt.md"))

        // Apps started from Finder get a bare PATH; claude may need its own directory on it.
        var environment = ProcessInfo.processInfo.environment
        let path = [URL(fileURLWithPath: claude).deletingLastPathComponent().path,
                    "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = path.joined(separator: ":")

        let arguments = [
            "--print",
            "--dangerously-skip-permissions",
            "--output-format", "json",
            "--json-schema", Self.schema,
            "--no-session-persistence",
            "--strict-mcp-config",
        ]
        let output = try Subprocess.run(
            claude, arguments,
            input: Data(prompt.utf8),
            environment: environment,
            directory: Support.directory
        ) { process in
            let keep = self.lock.withLock { () -> Bool in
                guard self.generation == current else { return false }
                self.process = process
                return true
            }
            if !keep { process.terminate() }
        }
        lock.withLock { if generation == current { process = nil } }
        try? output.stdout.write(to: Support.file("last-response.json"))
        return output
    }

    static func prompt(_ tabs: [Chrome.Tab], windowNumbers: [String: Int]) -> String {
        var text = Support.resource("prompt.md")
        if let rules = Support.extraRules() {
            text += "\n## The person's own rules\n\nThese take precedence over the rules above.\n\n\(rules)\n"
        }
        let windows = Set(windowNumbers.values).count
        text += "\n## Open tabs\n\n\(tabs.count) tabs in \(windows) windows, one per line: number | window | title | URL\n\n"
        for (index, tab) in tabs.enumerated() {
            let title = tab.title.isEmpty ? "(no title)" : clip(tab.title, 160)
            text += "\(index + 1) | w\(windowNumbers[tab.windowID] ?? 0) | \(title) | \(clip(tab.url, 200))\n"
        }
        return text
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return flat.count <= limit ? flat : flat.prefix(limit) + "…"
    }

    static func parse(_ output: Subprocess.Output, tabCount: Int, started: Date) throws -> Plan {
        guard let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any] else {
            let detail = output.errorText.isEmpty ? String(decoding: output.stdout.prefix(500), as: UTF8.self) : output.errorText
            throw Failure.claude("claude exited with status \(output.status). \(detail)")
        }
        if json["is_error"] as? Bool == true {
            throw Failure.claude("Claude reported an error: \(json["result"] as? String ?? "no details")")
        }

        struct Answer: Decodable { let close: [PlanItem] }
        var answer: Any? = json["structured_output"]
        if answer == nil, let text = json["result"] as? String {
            answer = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        }
        guard let answer,
              let data = try? JSONSerialization.data(withJSONObject: answer),
              let decoded = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw Failure.claude("Claude's answer wasn't in the expected shape. It is saved in "
                + Support.file("last-response.json").path)
        }

        var seen = Set<Int>()
        let close = decoded.close.filter { (1...tabCount).contains($0.tab) && seen.insert($0.tab).inserted }

        // Name the model that did the work (Claude Code may also use a small one on the side).
        let usage = json["modelUsage"] as? [String: [String: Any]] ?? [:]
        let model = usage.max { ($0.value["costUSD"] as? Double ?? 0) < ($1.value["costUSD"] as? Double ?? 0) }?.key

        return Plan(close: close, model: model, seconds: Date().timeIntervalSince(started))
    }

    /// The claude command: a `claudePath` default if set, the usual install
    /// locations, or whatever the login shell finds.
    static func claudePath() -> String? {
        let files = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "claudePath") {
            return files.isExecutableFile(atPath: custom) ? custom : nil
        }
        let home = files.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: files.isExecutableFile(atPath:)) {
            return found
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? Subprocess.run(shell, ["-l", "-c", "command -v claude"]), output.status == 0 else {
            return nil
        }
        let found = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return files.isExecutableFile(atPath: found) ? found : nil
    }
}
