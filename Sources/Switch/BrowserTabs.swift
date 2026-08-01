import AppKit

struct BrowserTab: Identifiable, Hashable {
    let id: String
    let browserName: String
    let bundleID: String
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String

    var searchText: String { "\(browserName) \(title) \(url)".lowercased() }
}

enum BrowserTabs {
    private struct Browser {
        let name: String
        let bundleID: String
        let processName: String
        let script: String
    }

    private static let browsers = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", processName: "Safari", script: safariScript),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", processName: "Google Chrome", script: chromiumScript(name: "Google Chrome")),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", processName: "Arc", script: chromiumScript(name: "Arc")),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", processName: "Brave Browser", script: chromiumScript(name: "Brave Browser")),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", processName: "Microsoft Edge", script: chromiumScript(name: "Microsoft Edge")),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", processName: "Vivaldi", script: chromiumScript(name: "Vivaldi"))
    ]

    static func snapshot() -> [BrowserTab] {
        browsers.flatMap { browser in
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty else { return [BrowserTab]() }
            return run(script: browser.script).compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 4,
                      let windowIndex = Int(fields[0]),
                      let tabIndex = Int(fields[1]),
                      !fields[2].isEmpty else { return nil }
                return BrowserTab(id: "\(browser.bundleID):\(windowIndex):\(tabIndex)", browserName: browser.name, bundleID: browser.bundleID, windowIndex: windowIndex, tabIndex: tabIndex, title: fields[2], url: fields[3])
            }
        }
    }

    static func activate(_ tab: BrowserTab) {
        guard let browser = browsers.first(where: { $0.bundleID == tab.bundleID }) else { return }
        _ = run(script: """
        tell application "\(browser.processName)"
            activate
            set active tab index of window \(tab.windowIndex) to \(tab.tabIndex)
            set index of window \(tab.windowIndex) to 1
        end tell
        """)
    }

    private static let safariScript = """
    tell application "Safari"
        set output to ""
        repeat with w from 1 to (count of windows)
            repeat with t from 1 to (count of tabs of window w)
                set tabRef to item t of tabs of window w
                set output to output & w & tab & t & tab & (name of tabRef) & tab & (URL of tabRef) & return
            end repeat
        end repeat
        return output
    end tell
    """

    private static func chromiumScript(name: String) -> String {
        """
        tell application "\(name)"
            set output to ""
            repeat with w from 1 to (count of windows)
                repeat with t from 1 to (count of tabs of window w)
                    set tabRef to item t of tabs of window w
                    set output to output & w & tab & t & tab & (title of tabRef) & tab & (URL of tabRef) & return
                end repeat
            end repeat
            return output
        end tell
        """
    }

    private static func run(script: String) -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return text.split(whereSeparator: \.isNewline).map(String.init)
        } catch {
            return []
        }
    }
}
