import Cocoa

/// Google Chrome, driven through its AppleScript dictionary. Each call runs one
/// of the scripts in Resources/scripts with osascript, so it blocks: call it off
/// the main thread.
enum Chrome {
    static let bundleID = "com.google.Chrome"

    // Chrome's AppleScript ids are strings of digits.
    struct Tab: Decodable {
        let windowID: String
        let id: String
        let title: String
        let url: String
    }

    struct Window: Decodable {
        let id: String
        let incognito: Bool
        let tabs: [Tab]
    }

    enum Failure: LocalizedError {
        case notAllowed
        case noAnswer
        case script(String)

        var errorDescription: String? {
            switch self {
            case .notAllowed:
                return "Tab Tidy isn't allowed to control Google Chrome. Turn it on in "
                    + "System Settings → Privacy & Security → Automation → Tab Tidy."
            case .noAnswer:
                return "Chrome didn't answer. If macOS asked whether Tab Tidy may control Google Chrome, "
                    + "click OK and try again."
            case .script(let message):
                return "Chrome didn't do what was asked: \(message)"
            }
        }
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Every window, front to back, with its tabs in order.
    static func windows() throws -> [Window] {
        guard isRunning else { return [] }
        let output = try script("list-tabs.js")
        return try JSONDecoder().decode([Window].self, from: Data(output.utf8))
    }

    /// Closes the tabs that still exist and returns how many that was.
    @discardableResult
    static func close(_ tabs: [Tab]) throws -> Int {
        guard !tabs.isEmpty else { return 0 }
        return Int(try script("close-tabs.applescript", pairs(tabs))) ?? 0
    }

    /// Gathers tabs at the end of another window and returns how many had to
    /// stay where they were. Chrome can't move a tab by script, so each one is
    /// reopened from its URL and reloads.
    static func merge(_ tabs: [Tab], into window: String) throws -> Int {
        guard !tabs.isEmpty else { return 0 }
        return Int(try script("merge-tabs.applescript", [window] + pairs(tabs))) ?? tabs.count
    }

    static func bringToFront(window: String) throws {
        try script("focus-window.applescript", [window])
    }

    /// Switches to the first tab whose URL starts with `prefix`. Returns false
    /// when there is no such tab.
    static func showTab(urlPrefix prefix: String) throws -> Bool {
        try script("show-tab.applescript", [prefix]) == "found"
    }

    /// Opens the URLs together in a new window.
    static func openWindow(_ urls: [String]) throws {
        guard !urls.isEmpty else { return }
        try script("open-window.applescript", urls)
    }

    /// Opens one URL in Chrome the way a clicked link would.
    static func open(_ url: URL) {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func pairs(_ tabs: [Tab]) -> [String] {
        tabs.flatMap { [$0.windowID, $0.id] }
    }

    @discardableResult
    private static func script(_ name: String, _ arguments: [String] = []) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "scripts") else {
            fatalError("scripts/\(name) is missing from the app bundle")
        }
        let language = url.pathExtension == "js" ? ["-l", "JavaScript"] : []
        let output = try Subprocess.run("/usr/bin/osascript", language + [url.path] + arguments)
        guard output.status == 0 else {
            // -1743: the person has not allowed (or has denied) Apple Events to Chrome.
            if output.errorText.contains("-1743") { throw Failure.notAllowed }
            // -1712: timed out, which is also what an unanswered permission prompt looks like.
            if output.errorText.contains("-1712") { throw Failure.noAnswer }
            throw Failure.script(output.errorText)
        }
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
