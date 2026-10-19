# Tab Tidy

A macOS menu bar app that cleans up Google Chrome. Click it, and Claude goes
through every open tab and proposes which ones to close. You review the plan on
a page in Chrome, change anything you disagree with, and approve. Tab Tidy then
closes those tabs and gathers everything that is left into a single window.

Nothing is closed until you approve.

## What it closes

The rules live in [`Resources/prompt.md`](Resources/prompt.md). In short:

| Closed | Examples |
|---|---|
| Duplicates | the same page open twice (tracking parameters and `#fragments` ignored); the first copy stays |
| Easy to reopen | Gmail, Google Calendar, chat apps, dashboards, home pages, search results, settings pages |
| Sign-in pages | sign-in, SSO, OAuth consent, two-factor, "signed out" pages |
| Redirects and jump pages | link shorteners, "you are being redirected", "you are leaving this site" |
| Blank and error pages | new tabs, `about:blank`, "page not found" |
| Finished flows | order confirmations, "thanks for subscribing", "download started" |

Anything with something to read (articles, docs, papers, videos, threads, a
specific document or pull request) stays open, on the assumption you haven't
read it yet. So does anything Claude is unsure about. You can close the rest by
hand from the final window.

## Requirements

- macOS 13 or later
- Google Chrome
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and signed in, so `claude` works in a terminal
- Apple Silicon for the released build; building from source works on any Mac

## Install

```sh
brew tap m-torun/tap
brew install --cask tab-tidy
```

Tab Tidy is signed ad hoc rather than with an Apple Developer ID, so macOS
blocks the first launch. Open it once with `open "/Applications/Tab Tidy.app"`,
then allow it under System Settings → Privacy & Security → **Open Anyway**.

Or [download the latest release](https://github.com/m-torun/tab-tidy/releases/latest)
and drag `Tab Tidy.app` to Applications.

To start it at login, right-click the menu bar icon and choose **Open at
Login**.

### Building from source

Needs Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/m-torun/tab-tidy.git
cd tab-tidy
./build.sh install
```

This builds `Tab Tidy.app`, copies it to `~/Applications` and starts it. Set
`INSTALL_DIR` to install somewhere else.

The first time it runs, macOS asks whether Tab Tidy may control Google Chrome.
Click **OK**. If you click Don't Allow, turn it on later in System Settings →
Privacy & Security → Automation.

## Use

- **Click** the menu bar icon to start a tidy. A review page opens in Chrome
  while Claude works, usually within a minute. Clicking again while a tidy is in
  progress brings that page back.
- **Right-click** it for the menu: reopen the tabs closed by the last tidy, edit
  your own rules, open at login, quit.
- Open `tabtidy://tidy` to start a tidy from Shortcuts, Raycast, Alfred or a script.

On the review page, every tab Claude wants to close is ticked and grouped with a
short reason. Untick any you want to keep, or open **Keeping** to tick more.
**Close and merge** does the rest, and the review page closes itself.

### How the merge works

Chrome's AppleScript can't move a tab between windows: its `move` command
leaves an empty tab behind. So Tab Tidy keeps the window that already has the
most tabs, reopens every other tab there from its URL, and closes the original.
Those pages reload and lose their back history, so finish anything you're typing
in another window before you approve. Pages that can't be reloaded from a URL
(`data:` and `blob:` addresses) stay in their own window.

If you use several Chrome profiles at once, the reopened tabs land in the
profile of the kept window.

## Your own rules

Right-click → **Edit Extra Rules…** opens
`~/Library/Application Support/Tab Tidy/rules.md`, which starts as a copy of
[`Resources/rules.example.md`](Resources/rules.example.md). Whatever you write
there in plain English is added to the prompt and wins over the built-in rules,
for example "Always keep tabs on github.com/my-org."

## How it works

1. Reads every tab's title and URL from Chrome with AppleScript
   ([`Resources/scripts`](Resources/scripts)). Incognito windows are skipped and
   left alone.
2. Serves the review page from a small HTTP server on `127.0.0.1`, behind a
   random token, and opens it in Chrome.
3. Runs Claude Code non-interactively with the default model:

   ```sh
   claude --print --dangerously-skip-permissions --output-format json \
       --json-schema '<plan schema>' --no-session-persistence --strict-mcp-config
   ```

   The prompt goes in on stdin. Permission prompts are skipped so the run never
   stops to ask anything; the prompt tells Claude to decide from titles and URLs
   alone without using tools. `--json-schema` makes the answer a list of
   `{tab, category, reason}`. `--strict-mcp-config` leaves out your MCP servers.
4. When you approve, it closes the chosen tabs by their Chrome ids (tabs opened
   since the plan was made are kept), merges the windows and brings the result
   to the front.

Tab titles and URLs are sent to Claude through Claude Code, under your own
Claude account. A run costs about as much as a short Claude Code session (about
$0.30 at API prices for 100 tabs).

### Where your settings live

Nothing specific to your Mac goes in this repository. Your settings and Tab
Tidy's records stay in the usual macOS places:

| What | Where |
|---|---|
| Your extra rules | `~/Library/Application Support/Tab Tidy/rules.md` |
| Latest prompt and Claude's raw answer, for troubleshooting | `~/Library/Application Support/Tab Tidy/last-prompt.md`, `last-response.json` |
| Tabs closed by the last tidy, for **Reopen** | `~/Library/Application Support/Tab Tidy/last-closed.json` |
| Path to `claude`, if Tab Tidy can't find it | the app's defaults: `defaults write io.github.m-torun.TabTidy claudePath /path/to/claude` |
| Open at Login | System Settings → General → Login Items |
| Build options | `INSTALL_DIR` and `SIGN_IDENTITY` environment variables |

To remove everything: quit Tab Tidy, delete the app, the
`~/Library/Application Support/Tab Tidy` folder, and run
`defaults delete io.github.m-torun.TabTidy`.

## Rebuilding

`./build.sh` signs the app ad hoc, which macOS treats as a new app after every
build, so it asks for permission to control Chrome again. Set `SIGN_IDENTITY` to
a code signing identity from your keychain to avoid that.

## License

MIT
