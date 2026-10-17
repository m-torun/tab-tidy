import Foundation

/// One tidy at a time: snapshot the tabs, ask Claude for a plan, show it on a
/// local page in Chrome, and once approved close the chosen tabs and gather
/// the rest into one window. Everything here runs on the main queue except the
/// Chrome calls, which go through `chromeQueue`.
final class Tidy {
    enum Phase: String {
        case idle, thinking, ready, applying, failed
    }

    var onPhaseChange: ((Phase) -> Void)?
    var onAlert: ((String, String) -> Void)?

    private(set) var phase = Phase.idle {
        didSet { onPhaseChange?(phase) }
    }
    private(set) var lastSummary: String?

    private var server: HTTPServer?
    private let token = UUID().uuidString.lowercased()
    private let planner = Planner()
    private let chromeQueue = DispatchQueue(label: "Tab Tidy Chrome")

    /// The tabs as they were when the plan was made, numbered from 1 in the
    /// prompt and on the page.
    private var tabs: [Chrome.Tab] = []
    private var windowNumbers: [String: Int] = [:]
    private var plan: Plan?
    private var error: String?
    private var startedAt = Date()

    private var pageURL: String {
        "http://127.0.0.1:\(server?.port ?? 0)/\(token)/"
    }

    func start() {
        do {
            let server = try HTTPServer { [weak self] request in
                self?.handle(request) ?? .status(503)
            }
            server.start { [weak self] error in
                self?.onAlert?("Tab Tidy's page server stopped", error.localizedDescription)
            }
            self.server = server
        } catch {
            onAlert?("Tab Tidy couldn't start its page server", error.localizedDescription)
        }
    }

    /// Called when the app quits, so a running claude doesn't outlive it.
    func stop() {
        planner.cancel()
    }

    // MARK: Menu bar actions

    /// Starts a tidy, or brings back the page for the one in progress.
    func begin() {
        switch phase {
        case .thinking, .ready, .applying:
            let url = pageURL
            chromeQueue.async {
                if (try? Chrome.showTab(urlPrefix: url)) != true {
                    DispatchQueue.main.async { self.openPage() }
                }
            }
        case .idle, .failed:
            plan(openingPage: true)
        }
    }

    func reopenLastClosed() {
        let urls = History.load().map(\.url)
        chromeQueue.async {
            do {
                try Chrome.openWindow(urls)
                History.clear()
            } catch {
                self.alert("Couldn't reopen the tabs", error)
            }
        }
    }

    // MARK: Planning

    private func plan(openingPage: Bool) {
        guard server?.port ?? 0 != 0 else {
            onAlert?("Tab Tidy isn't ready", "Its page server hasn't started. Try again in a moment.")
            return
        }
        planner.cancel()
        phase = .thinking
        plan = nil
        error = nil
        startedAt = Date()

        chromeQueue.async {
            let windows = Result { try Chrome.windows() }
            DispatchQueue.main.async { self.plan(windows, openingPage: openingPage) }
        }
    }

    private func plan(_ windows: Result<[Chrome.Window], Error>, openingPage: Bool) {
        guard phase == .thinking else { return }
        let found: [Chrome.Window]
        switch windows {
        case .success(let value): found = value
        case .failure(let failure):
            return fail(failure.localizedDescription, pageIsOpen: !openingPage)
        }

        // Incognito windows are left alone: their tabs are not sent anywhere.
        tabs = []
        windowNumbers = [:]
        for window in found where !window.incognito {
            let real = window.tabs.filter { !isPlanPage($0) }
            guard !real.isEmpty else { continue }
            windowNumbers[window.id] = windowNumbers.count + 1
            tabs += real
        }
        guard !tabs.isEmpty else {
            let reason = Chrome.isRunning ? "Chrome has no tabs open outside incognito windows." : "Chrome isn't running."
            return fail(reason, pageIsOpen: !openingPage)
        }

        if openingPage { openPage() }
        planner.run(tabs, windowNumbers: windowNumbers) { result in
            switch result {
            case .success(let plan):
                self.plan = plan
                self.phase = .ready
            case .failure(let failure):
                self.fail(failure.localizedDescription, pageIsOpen: true)
            }
        }
    }

    private func fail(_ message: String, pageIsOpen: Bool) {
        error = message
        if pageIsOpen {
            phase = .failed
        } else {
            phase = .idle
            onAlert?("Tab Tidy can't tidy right now", message)
        }
    }

    private func openPage() {
        if let url = URL(string: pageURL) { Chrome.open(url) }
    }

    private func isPlanPage(_ tab: Chrome.Tab) -> Bool {
        // Also catches pages left over from an earlier launch, which used another port.
        tab.url.hasPrefix(pageURL) || (tab.url.hasPrefix("http://127.0.0.1:") && tab.title == "Tab Tidy")
    }

    // MARK: Applying

    private func apply(closing numbers: [Int]) {
        guard phase == .ready else { return }
        phase = .applying
        let chosen = Set(numbers).sorted().compactMap { tabs.indices.contains($0 - 1) ? tabs[$0 - 1] : nil }

        chromeQueue.async {
            let outcome = Result { try self.closeAndMerge(chosen) }
            DispatchQueue.main.async {
                self.phase = .idle
                switch outcome {
                case .success(let summary):
                    self.lastSummary = summary.text
                    if summary.unmoved > 0 {
                        self.onAlert?("Some tabs stayed in their own window", summary.unmovedText)
                    }
                case .failure(let failure):
                    self.onAlert?("Tab Tidy didn't finish", failure.localizedDescription)
                }
            }
        }
    }

    private struct Summary {
        let closed: Int
        let merged: Int
        let unmoved: Int

        var text: String {
            "Last tidy: closed \(closed) \(closed == 1 ? "tab" : "tabs"), merged \(merged) \(merged == 1 ? "window" : "windows")"
        }

        var unmovedText: String {
            "\(unmoved) \(unmoved == 1 ? "tab" : "tabs") couldn't be reopened in the main window "
                + "(pages with data: or blob: addresses can't be reloaded), so they stayed in their own window."
        }
    }

    /// Runs on `chromeQueue`. Tabs are found again by id, so anything opened or
    /// closed since the plan was made is handled correctly.
    private func closeAndMerge(_ chosen: [Chrome.Tab]) throws -> Summary {
        if !chosen.isEmpty { History.save(chosen) }
        let closed = try Chrome.close(chosen)

        let windows = try Chrome.windows().filter { !$0.incognito }
        let planPages = windows.flatMap(\.tabs).filter(isPlanPage)
        let remaining = windows
            .map { (id: $0.id, tabs: $0.tabs.filter { !isPlanPage($0) }) }
            .filter { !$0.tabs.isEmpty }

        // Gather into the window that already holds the most tabs (the frontmost on a tie).
        var merged = 0
        var unmoved = 0
        let target = remaining.max { $0.tabs.count < $1.tabs.count }
        if let target {
            for window in remaining where window.id != target.id {
                let stayed = try Chrome.merge(window.tabs, into: target.id)
                unmoved += stayed
                if stayed < window.tabs.count { merged += 1 }
            }
        }
        try Chrome.close(planPages)
        if let target { try Chrome.bringToFront(window: target.id) }
        return Summary(closed: closed, merged: merged, unmoved: unmoved)
    }

    private func cancel() {
        planner.cancel()
        phase = .idle
        chromeQueue.async {
            if let pages = try? Chrome.windows().flatMap(\.tabs).filter(self.isPlanPage) {
                _ = try? Chrome.close(pages)
            }
        }
    }

    private func alert(_ title: String, _ error: Error) {
        DispatchQueue.main.async { self.onAlert?(title, error.localizedDescription) }
    }

    // MARK: The page

    private struct PageState: Encodable {
        struct Tab: Encodable {
            let n: Int
            let window: Int
            let title: String
            let url: String
        }

        let phase: String
        let startedAt: Double
        let windows: Int
        let tabs: [Tab]
        let close: [PlanItem]
        let model: String?
        let seconds: Double?
        let error: String?
    }

    private var pageState: PageState {
        PageState(
            phase: phase.rawValue,
            startedAt: startedAt.timeIntervalSince1970 * 1000,
            windows: Set(windowNumbers.values).count,
            tabs: tabs.enumerated().map { index, tab in
                PageState.Tab(n: index + 1, window: windowNumbers[tab.windowID] ?? 0, title: tab.title, url: tab.url)
            },
            close: plan?.close ?? [],
            model: plan?.model,
            seconds: plan?.seconds,
            error: error
        )
    }

    private struct ApplyRequest: Decodable {
        let close: [Int]
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        // Only this page may talk to the server: the random token in the path keeps
        // other sites out, and the Host check stops DNS rebinding.
        guard request.headers["host"] == "127.0.0.1:\(server?.port ?? 0)" else { return .status(403) }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { return .status(404) }

        switch (request.method, path.dropFirst(prefix.count)) {
        case ("GET", ""):
            return .html(Support.resource("plan.html"))
        case ("GET", "api/state"):
            return .json(pageState)
        case ("POST", "api/apply"):
            guard let body = try? JSONDecoder().decode(ApplyRequest.self, from: request.body) else { return .status(400) }
            apply(closing: body.close)
        case ("POST", "api/retry"):
            plan(openingPage: false)
        case ("POST", "api/cancel"):
            cancel()
        default:
            return .status(404)
        }
        return .json(pageState)
    }
}
