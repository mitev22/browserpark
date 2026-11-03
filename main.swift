// browserpark: keeps automated Chrome windows off the desktop without breaking their pages.
//
//   browserpark                               menu bar app
//   browserpark status                        one line per browser
//   browserpark park|show|toggle <name>|all   by name
//   browserpark park|show|toggle --port N     by CDP port
//   browserpark proxy --port N                stop tab commands taking focus: connect clients to N + 10000
//
// Why off-screen and not Cmd-H or minimise: both flip document.visibilityState to "hidden" and stall
// requestAnimationFrame, which breaks pages that wait to be visible. See README.md.
//
// While running, the menu bar app also parks new windows that appear in an instance that is already parked.
// It doesn't fight Chrome for keyboard focus: it can't tell an agent's activation from the user's swipe,
// Cmd-Tab or Dock click, and bouncing focus back threw users out of the desktop (2026-11-03). The proxy
// stops agents taking focus instead.

import AppKit

struct ConfiguredBrowser: Decodable {
    let name: String
    let port: Int
    let start: String?
}

struct Browser {
    let name: String
    let port: Int
    var pid: pid_t? = nil
    var start: String? = nil
    // Without this flag Chrome marks an off-screen window as occluded and the page goes hidden.
    var hasOcclusionFlag = true
}

let configPath = (ProcessInfo.processInfo.environment["BROWSERPARK_CONFIG"]
    ?? "~/.config/browserpark/config.json" as String)

func loadConfig() -> [ConfiguredBrowser] {
    let path = NSString(string: configPath).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    do {
        return try JSONDecoder().decode([ConfiguredBrowser].self, from: data)
    } catch {
        FileHandle.standardError.write(Data("browserpark: ignoring \(path): \(error.localizedDescription)\n".utf8))
        return []
    }
}

func runOutput(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func flagValue(_ flag: String, in args: String) -> String? {
    // Values can contain spaces (profile paths), so a value runs up to the next " --" or the end.
    guard let start = args.range(of: "--\(flag)=") else { return nil }
    let rest = args[start.upperBound...]
    let end = rest.range(of: " --")?.lowerBound ?? rest.endIndex
    return rest[..<end].trimmingCharacters(in: .whitespaces)
}

func derivedName(profile: String?, port: Int) -> String {
    guard let profile else { return "port \(port)" }
    let base = URL(fileURLWithPath: profile).lastPathComponent
    return base.hasPrefix(".") ? String(base.dropFirst()) : base
}

// Every visible Chrome with remote debugging on, plus configured ones that aren't running.
// Headless browsers are skipped because they have no window to park.
func discoverBrowsers() -> [Browser] {
    let config = loadConfig()
    var found: [Browser] = []
    for line in runOutput("/bin/ps", ["-axww", "-o", "pid=,args="]).split(separator: "\n") {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.contains("--remote-debugging-port="), !text.contains("--type="), !text.contains("--headless"),
              let space = text.firstIndex(of: " "), let pid = pid_t(text[..<space]) else { continue }
        let args = String(text[space...])
        // A shell or script can have the flag in its own command line, so check what's actually running.
        let executable = (args.range(of: " --").map { String(args[..<$0.lowerBound]) } ?? args).lowercased()
        guard executable.contains(".app/contents/macos/") || executable.contains("chrome") || executable.contains("chromium") else { continue }
        let profile = flagValue("user-data-dir", in: args)
        var port = Int(flagValue("remote-debugging-port", in: args) ?? "") ?? 0
        if port == 0, let profile,
           let active = try? String(contentsOfFile: "\(profile)/DevToolsActivePort", encoding: .utf8) {
            // --remote-debugging-port=0 picks a random port and writes it here.
            port = Int(active.split(separator: "\n").first ?? "") ?? 0
        }
        guard port != 0 else { continue }
        let configured = config.first { $0.port == port }
        found.append(Browser(name: configured?.name ?? derivedName(profile: profile, port: port),
                             port: port, pid: pid, start: configured?.start,
                             hasOcclusionFlag: args.contains("--disable-backgrounding-occluded-windows")))
    }
    for entry in config where !found.contains(where: { $0.port == entry.port }) {
        found.append(Browser(name: entry.name, port: entry.port, pid: nil, start: entry.start))
    }
    return found.sorted { $0.name < $1.name }
}

struct WindowInfo {
    let id: Int
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let state: String
}

enum Geometry {
    // CDP uses top-left origin coordinates, AppKit uses bottom-left.
    static func toTopLeft(_ rect: NSRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static var desktop: NSRect {
        NSScreen.screens.map { toTopLeft($0.frame) }.reduce(NSRect.null) { $0.union($1) }
    }

    // macOS clamps these, leaving a roughly 40x40 corner in the bottom-left.
    static func parkedOrigin(width: Int) -> (left: Int, top: Int) {
        (Int(desktop.minX) - width - 5000, Int(desktop.maxY) + 5000)
    }

    static func isParked(_ w: WindowInfo) -> Bool {
        w.left + w.width <= Int(desktop.minX) + 100
    }

    static func shownBounds(_ w: WindowInfo, index: Int) -> (left: Int, top: Int, width: Int, height: Int) {
        let area = toTopLeft((NSScreen.main ?? NSScreen.screens[0]).visibleFrame)
        let width = min(w.width, Int(area.width))
        let height = min(w.height, Int(area.height))
        let offset = index * 28
        return (Int(area.midX) - width / 2 + offset, Int(area.midY) - height / 2 + offset, width, height)
    }
}

final class CDP: @unchecked Sendable {
    private let ws: URLSessionWebSocketTask
    private var nextId = 0

    static func get(_ port: Int, _ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 1
        return try await URLSession.shared.data(for: request).0
    }

    init(port: Int) async throws {
        let data = try await CDP.get(port, "/json/version")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let raw = json?["webSocketDebuggerUrl"] as? String, let url = URL(string: raw) else {
            throw URLError(.badServerResponse)
        }
        ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
    }

    deinit { close() }

    func close() { ws.cancel(with: .goingAway, reason: nil) }

    func send(_ method: String, _ params: [String: Any] = [:], sessionId: String? = nil) async throws -> [String: Any] {
        nextId += 1
        let id = nextId
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId { message["sessionId"] = sessionId }
        let body = try JSONSerialization.data(withJSONObject: message)
        try await ws.send(.string(String(decoding: body, as: UTF8.self)))
        while true {
            guard case .string(let text) = try await ws.receive(),
                  let reply = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  reply["id"] as? Int == id else { continue }
            if let error = reply["error"] as? [String: Any] {
                throw NSError(domain: "CDP", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
            }
            return reply["result"] as? [String: Any] ?? [:]
        }
    }
}

struct Instance {
    var running = false
    var windows: [WindowInfo] = []
    var pageTitle = ""
    var parked: Bool { running && !windows.isEmpty && windows.allSatisfy(Geometry.isParked) }
}

func windowInfo(_ reply: [String: Any], id: Int) -> WindowInfo? {
    guard let b = reply["bounds"] as? [String: Any] else { return nil }
    return WindowInfo(id: id, left: b["left"] as? Int ?? 0, top: b["top"] as? Int ?? 0,
                      width: b["width"] as? Int ?? 1200, height: b["height"] as? Int ?? 800,
                      state: b["windowState"] as? String ?? "normal")
}

func inspect(port: Int) async -> Instance {
    guard let data = try? await CDP.get(port, "/json/list"),
          let targets = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return Instance()
    }
    var instance = Instance(running: true)
    let pages = targets.filter { $0["type"] as? String == "page" }
    instance.pageTitle = pages.first?["title"] as? String ?? ""
    guard let cdp = try? await CDP(port: port) else { return instance }
    var seen = Set<Int>()
    for page in pages {
        guard let targetId = page["id"] as? String,
              let reply = try? await cdp.send("Browser.getWindowForTarget", ["targetId": targetId]),
              let id = reply["windowId"] as? Int, seen.insert(id).inserted,
              let info = windowInfo(reply, id: id) else { continue }
        instance.windows.append(info)
    }
    return instance
}

func setBounds(_ cdp: CDP, _ window: WindowInfo, _ bounds: [String: Any]) async throws {
    // Chrome refuses position changes unless the window is in the normal state.
    if window.state != "normal" {
        _ = try await cdp.send("Browser.setWindowBounds", ["windowId": window.id, "bounds": ["windowState": "normal"]])
        try await Task.sleep(nanoseconds: window.state == "fullscreen" ? 1_500_000_000 : 300_000_000)
    }
    _ = try await cdp.send("Browser.setWindowBounds", ["windowId": window.id, "bounds": bounds])
}

func park(port: Int, only: Set<Int>? = nil) async throws {
    let instance = await inspect(port: port)
    guard instance.running else { throw URLError(.cannotConnectToHost) }
    let cdp = try await CDP(port: port)
    for window in instance.windows where only?.contains(window.id) ?? true {
        let origin = Geometry.parkedOrigin(width: window.width)
        try await setBounds(cdp, window, ["left": origin.left, "top": origin.top])
    }
}

func show(port: Int, pid: pid_t?) async throws {
    let instance = await inspect(port: port)
    guard instance.running else { throw URLError(.cannotConnectToHost) }
    let cdp = try await CDP(port: port)
    for (index, window) in instance.windows.enumerated() {
        let b = Geometry.shownBounds(window, index: index)
        try await setBounds(cdp, window, ["left": b.left, "top": b.top, "width": b.width, "height": b.height])
    }
    if let pid, let app = NSRunningApplication(processIdentifier: pid) {
        app.unhide()
        app.activate(options: [])
    }
}

func toggle(port: Int, pid: pid_t?) async throws {
    if await inspect(port: port).parked { try await show(port: port, pid: pid) } else { try await park(port: port) }
}

@MainActor
final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var browsers: [Browser] = []
    private var instances: [Int: Instance] = [:]
    private var knownWindows: [Int: Set<Int>] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Browsers")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Task { await refresh() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func refresh() async {
        browsers = discoverBrowsers()
        // Forget browsers that exited, so a new Chrome on the same port doesn't inherit parked state.
        let ports = Set(browsers.map(\.port))
        instances = instances.filter { ports.contains($0.key) }
        knownWindows = knownWindows.filter { ports.contains($0.key) }
        for browser in browsers {
            let port = browser.port
            let current = await inspect(port: port)
            let wasParked = instances[port]?.parked ?? false
            let known = knownWindows[port] ?? []
            instances[port] = current
            knownWindows[port] = Set(current.windows.map(\.id))
            guard current.running else { continue }

            // A parked instance stays parked when a new window pops up.
            let newOnScreen = current.windows.filter { !known.contains($0.id) && !Geometry.isParked($0) }
            if wasParked && !newOnScreen.isEmpty {
                try? await park(port: port, only: Set(newOnScreen.map(\.id)))
                instances[port] = await inspect(port: port)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if browsers.isEmpty {
            let empty = NSMenuItem(title: "No debuggable Chrome running", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, browser) in browsers.enumerated() {
            let instance = instances[browser.port] ?? Instance()
            let label: String
            if !instance.running {
                label = browser.start == nil ? "not running" : "not running, click to start"
            } else {
                label = (instance.parked ? "parked" : "showing") + (browser.hasOcclusionFlag ? "" : " (pages stall when parked, see README)")
            }
            let item = NSMenuItem(title: "\(browser.name): \(label)", action: #selector(clicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = instance.running && !instance.parked ? .on : .off
            if instance.running && !instance.pageTitle.isEmpty {
                item.subtitle = String(instance.pageTitle.prefix(48))
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let parkAll = NSMenuItem(title: "Park all", action: #selector(parkAll(_:)), keyEquivalent: "")
        parkAll.target = self
        menu.addItem(parkAll)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    @objc private func clicked(_ sender: NSMenuItem) {
        let browser = browsers[sender.tag]
        let instance = instances[browser.port] ?? Instance()
        Task {
            if instance.running {
                try? await toggle(port: browser.port, pid: browser.pid)
            } else if let start = browser.start {
                await run(start)
                let pid = discoverBrowsers().first { $0.port == browser.port }?.pid
                try? await show(port: browser.port, pid: pid)
            }
            await refresh()
        }
    }

    @objc private func parkAll(_ sender: NSMenuItem) {
        Task {
            for browser in browsers { try? await park(port: browser.port) }
            await refresh()
        }
    }

    private func run(_ start: String) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", start]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(env["PATH"] ?? "")"
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in done.resume() }
            if (try? process.run()) == nil { done.resume() }
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("browserpark: \(message)\n".utf8))
    exit(1)
}

func runCLI(_ args: [String]) async {
    let command = args[0]
    if command == "proxy" {
        guard args.count == 3, args[1] == "--port", let port = Int(args[2]) else { fail("usage: browserpark proxy --port N") }
        await runProxy(chromePort: port)
        return
    }
    let browsers = discoverBrowsers()
    if command == "status" {
        for browser in browsers {
            let instance = await inspect(port: browser.port)
            let state = !instance.running ? "down" : instance.parked ? "parked" : "showing"
            print("\(browser.name)\t\(browser.port)\t\(state)\(browser.hasOcclusionFlag ? "" : "\tmissing-occlusion-flag")")
        }
        return
    }

    guard ["park", "show", "toggle"].contains(command), args.count >= 2 else {
        fail("usage: browserpark [status | park|show|toggle <name>|all | park|show|toggle --port N | proxy --port N]")
    }
    var targets: [Browser]
    if args[1] == "--port" {
        guard args.count == 3, let port = Int(args[2]) else { fail("--port needs a number") }
        targets = [browsers.first { $0.port == port } ?? Browser(name: "port \(port)", port: port)]
    } else if args[1] == "all" {
        targets = browsers
    } else {
        guard let browser = browsers.first(where: { $0.name == args[1] }) else { fail("no browser named \(args[1])") }
        targets = [browser]
    }

    for target in targets {
        do {
            switch command {
            case "park": try await park(port: target.port)
            case "show": try await show(port: target.port, pid: target.pid)
            default: try await toggle(port: target.port, pid: target.pid)
            }
        } catch {
            if args[1] != "all" { fail("port \(target.port): \(error.localizedDescription)") }
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let delegate = MenuApp()
        app.delegate = delegate
        app.run()
    }
} else {
    _ = NSApplication.shared // NSScreen needs a connection to the window server.
    Task {
        await runCLI(arguments)
        exit(0)
    }
    dispatchMain()
}
