import Foundation

/// Files Tab Tidy keeps in ~/Library/Application Support/Tab Tidy.
enum Support {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Tab Tidy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// The person's own rules, added to the prompt. Starts as a copy of
    /// rules.example.md the first time it is opened from the menu.
    static func rulesFile() -> URL {
        let url = file("rules.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data(resource("rules.example.md").utf8).write(to: url)
        }
        return url
    }

    /// The rules file without comments, or nil when there is nothing in it.
    static func extraRules() -> String? {
        guard let text = try? String(contentsOf: file("rules.md"), encoding: .utf8) else { return nil }
        let stripped = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// Text of a file bundled in the app's Resources folder.
    static func resource(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("\(name) is missing from the app bundle")
        }
        return text
    }
}

/// The tabs closed by the last tidy, so they can be reopened from the menu.
enum History {
    struct Entry: Codable {
        let title: String
        let url: String
    }

    private static var url: URL { Support.file("last-closed.json") }

    static func save(_ tabs: [Chrome.Tab]) {
        let entries = tabs.map { Entry(title: $0.title, url: $0.url) }
        try? JSONEncoder().encode(entries).write(to: url)
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs a command to completion and collects its output.
enum Subprocess {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var errorText: String {
            String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// `started` is called once the process is running, for callers that may
    /// need to terminate it.
    static func run(
        _ path: String,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String]? = nil,
        directory: URL? = nil,
        started: ((Process) -> Void)? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        try process.run()
        started?(process)

        // Read and write on separate threads so a full pipe never blocks the other side.
        let group = DispatchGroup()
        var errorData = Data()
        DispatchQueue.global().async(group: group) {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        if let input {
            DispatchQueue.global().async(group: group) {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: outputData, stderr: errorData)
    }
}
