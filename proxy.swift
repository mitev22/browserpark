// browserpark proxy: sits between an automation client and Chrome's debugging port so that opening or
// selecting a tab doesn't take the user's keyboard focus.
//
// Chrome makes itself the active app when a tab is selected over CDP. Only the client's requests can
// avoid that, so the proxy rewrites them:
//   Target.createTarget,
//   GET/PUT /json/new       -> opens in its own background window, because a background tab in a shared
//                              window reports document.visibilityState "hidden" and stalls
//   Target.activateTarget,
//   Page.bringToFront       -> answered without reaching Chrome when the tab is already showing in its window
// Selecting a hidden tab in a shared window still reaches Chrome, because nothing else can make it visible.

import CryptoKit
import Foundation
import Network

let proxyPortOffset = 10000

func proxyLog(_ message: @autoclosure () -> String) {
    guard let path = ProcessInfo.processInfo.environment["BROWSERPARK_PROXY_LOG"],
          let handle = FileHandle(forWritingAtPath: path) else { return }
    handle.seekToEndOfFile()
    handle.write(Data((message() + "\n").utf8))
    try? handle.close()
}

func receiveData(_ connection: NWConnection) async -> Data? {
    await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                done.resume(returning: data)
            } else if isComplete || error != nil {
                done.resume(returning: nil)
            } else {
                done.resume(returning: Data())
            }
        }
    }
}

func sendData(_ connection: NWConnection, _ data: Data) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        connection.send(content: data, completion: .contentProcessed { _ in done.resume() })
    }
}

enum WebSocketFrame {
    static func encode(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    // Removes one complete client frame from the front of `buffer`, or returns nil if it isn't all here yet.
    static func decode(_ buffer: inout Data) -> (fin: Bool, opcode: UInt8, payload: Data)? {
        let bytes = buffer.startIndex
        guard buffer.count >= 2 else { return nil }
        let fin = buffer[bytes] & 0x80 != 0
        let opcode = buffer[bytes] & 0x0F
        let masked = buffer[bytes + 1] & 0x80 != 0
        var length = Int(buffer[bytes + 1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = Int(buffer[bytes + 2]) << 8 | Int(buffer[bytes + 3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = (0..<8).reduce(0) { $0 << 8 | Int(buffer[bytes + 2 + $1]) }
            offset = 10
        }
        let maskLength = masked ? 4 : 0
        guard buffer.count >= offset + maskLength + length else { return nil }
        var payload = Data(buffer[(bytes + offset + maskLength)..<(bytes + offset + maskLength + length)])
        if masked {
            let mask = Array(buffer[(bytes + offset)..<(bytes + offset + 4)])
            payload.withUnsafeMutableBytes { raw in
                for index in 0..<raw.count { raw[index] ^= mask[index % 4] }
            }
        }
        buffer = Data(buffer[(bytes + offset + maskLength + length)...])
        return (fin, opcode, payload)
    }
}

final class ProxyServer {
    let chromePort: Int
    let listenPort: Int
    private let session: URLSession
    private var listener: NWListener?

    init(chromePort: Int, listenPort: Int) {
        self.chromePort = chromePort
        self.listenPort = listenPort
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3600 * 24 * 365
        configuration.timeoutIntervalForResource = 3600 * 24 * 365
        session = URLSession(configuration: configuration)
    }

    // A port freed a moment ago, for example by a Chrome that just quit, can stay busy for a few
    // seconds, so keep trying for half a minute before giving up.
    func start(attempt: Int = 1) throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(listenPort)) else { throw URLError(.badURL) }
        let parameters = NWParameters.tcp
        // Loopback only: anything that can reach this port can control the browser.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            Task { await self?.handle(connection) }
        }
        listener.stateUpdateHandler = { [weak self, listenPort] state in
            guard case .failed(let error) = state else { return }
            listener.cancel()
            guard attempt < 30, let self else { fail("can't listen on port \(listenPort): \(error)") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { try? self.start(attempt: attempt + 1) }
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) async {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard let data = await receiveData(connection), buffer.count < 65536 else {
                connection.cancel()
                return
            }
            buffer.append(data)
        }
        let headEnd = buffer.range(of: separator)!
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        let rest = Data(buffer[headEnd.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ").map(String.init)
        guard request.count >= 2 else {
            connection.cancel()
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            await bridge(connection, path: request[1], key: key, pending: rest)
        } else {
            await forwardHTTP(connection, method: request[0], path: request[1])
        }
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String, body: Data) async {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        await sendData(connection, Data(head.utf8) + body)
        connection.cancel()
    }

    private func forwardHTTP(_ connection: NWConnection, method: String, path: String) async {
        if path.hasPrefix("/json/activate/") {
            let target = String(path.dropFirst("/json/activate/".count))
            if await !mustSelect(targetId: target) {
                await respond(connection, status: 200, contentType: "text/plain", body: Data("Target activated".utf8))
                return
            }
        }
        if path.hasPrefix("/json/new") {
            await openTab(connection, path: path)
            return
        }
        guard let url = URL(string: "http://127.0.0.1:\(chromePort)\(path)") else {
            await respond(connection, status: 400, contentType: "text/plain", body: Data())
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            await respond(connection, status: 502, contentType: "text/plain", body: Data("Chrome is not reachable".utf8))
            return
        }
        // Clients connect to the WebSocket URLs in these replies, so they must point back at the proxy.
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "127.0.0.1:\(chromePort)", with: "127.0.0.1:\(listenPort)")
            .replacingOccurrences(of: "localhost:\(chromePort)", with: "127.0.0.1:\(listenPort)")
        await respond(connection, status: http.statusCode,
                      contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "application/json", body: Data(text.utf8))
    }

    // GET/PUT /json/new?<url> would open a foreground tab in an existing window and take focus,
    // so it's done the same way as Target.createTarget instead.
    private func openTab(_ connection: NWConnection, path: String) async {
        let query = path.firstIndex(of: "?").map { String(path[path.index(after: $0)...]) } ?? ""
        let address = query.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
        guard let cdp = try? await CDP(port: chromePort),
              let created = try? await cdp.send("Target.createTarget", await backgroundWindowParams(["url": address])),
              let targetId = created["targetId"] as? String else {
            await respond(connection, status: 500, contentType: "text/plain", body: Data("Could not open the tab".utf8))
            return
        }
        let list = (try? await CDP.get(chromePort, "/json/list")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        let target = list?.first { $0["id"] as? String == targetId } ?? ["id": targetId, "type": "page", "url": address]
        let body = (try? JSONSerialization.data(withJSONObject: target)) ?? Data()
        let text = String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "127.0.0.1:\(chromePort)", with: "127.0.0.1:\(listenPort)")
            .replacingOccurrences(of: "localhost:\(chromePort)", with: "127.0.0.1:\(listenPort)")
        await respond(connection, status: 200, contentType: "application/json", body: Data(text.utf8))
    }

    func backgroundWindowParams(_ params: [String: Any]) async -> [String: Any] {
        var updated = params
        updated["newWindow"] = true
        updated["background"] = true
        let instance = await inspect(port: chromePort)
        let width = (updated["width"] as? Int) ?? instance.windows.first?.width ?? 1280
        updated["width"] = width
        updated["height"] = updated["height"] ?? instance.windows.first?.height ?? 900
        // No windows yet means Chrome was started with --no-startup-window to stay out of the way, so park.
        if instance.parked || instance.windows.isEmpty {
            let origin = Geometry.parkedOrigin(width: width)
            updated["left"] = origin.left
            updated["top"] = origin.top
        }
        return updated
    }

    // False when selecting the tab would change nothing except stealing focus.
    func mustSelect(targetId: String) async -> Bool {
        guard let data = try? await CDP.get(chromePort, "/json/list"),
              let targets = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let cdp = try? await CDP(port: chromePort) else { return true }
        // A hung page must not hang the client, so give up and let Chrome handle it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { cdp.close() }
        do {
            let mine = try await cdp.send("Browser.getWindowForTarget", ["targetId": targetId])["windowId"] as? Int
            var sharesWindow = false
            for page in targets where page["type"] as? String == "page" {
                guard let other = page["id"] as? String, other != targetId,
                      let reply = try? await cdp.send("Browser.getWindowForTarget", ["targetId": other]) else { continue }
                if reply["windowId"] as? Int == mine { sharesWindow = true }
            }
            if !sharesWindow { return false }
            let attached = try await cdp.send("Target.attachToTarget", ["targetId": targetId, "flatten": true])
            guard let sessionId = attached["sessionId"] as? String else { return true }
            let result = try await cdp.send("Runtime.evaluate", ["expression": "document.visibilityState"], sessionId: sessionId)
            return (result["result"] as? [String: Any])?["value"] as? String != "visible"
        } catch {
            return true
        }
    }

    private func bridge(_ connection: NWConnection, path: String, key: String, pending: Data) async {
        guard let url = URL(string: "ws://127.0.0.1:\(chromePort)\(path)") else {
            connection.cancel()
            return
        }
        let upstream = session.webSocketTask(with: url)
        // Screenshots arrive as a single large message.
        upstream.maximumMessageSize = 1 << 30
        upstream.resume()
        let connected = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            upstream.sendPing { done.resume(returning: $0 == nil) }
        }
        guard connected else {
            await respond(connection, status: 502, contentType: "text/plain", body: Data("Chrome is not reachable".utf8))
            return
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        await sendData(connection, Data(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n").utf8))
        await ProxiedSocket(server: self, client: connection, upstream: upstream, path: path).run(pending: pending)
    }
}

final class ProxiedSocket {
    private let server: ProxyServer
    private let client: NWConnection
    private let upstream: URLSessionWebSocketTask
    private let pageTarget: String?
    private let lock = NSLock()
    private var sessionTargets: [String: String] = [:]

    init(server: ProxyServer, client: NWConnection, upstream: URLSessionWebSocketTask, path: String) {
        self.server = server
        self.client = client
        self.upstream = upstream
        pageTarget = path.hasPrefix("/devtools/page/") ? String(path.dropFirst("/devtools/page/".count)) : nil
    }

    func run(pending: Data) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pumpClient(pending: pending) }
            group.addTask { await self.pumpUpstream() }
            await group.next()
            // Either side closing ends both.
            upstream.cancel(with: .goingAway, reason: nil)
            client.cancel()
        }
    }

    private func pumpClient(pending: Data) async {
        var buffer = pending
        var message = Data()
        var messageOpcode: UInt8 = 1
        while true {
            while let frame = WebSocketFrame.decode(&buffer) {
                switch frame.opcode {
                case 8:
                    return
                case 9:
                    await sendData(client, WebSocketFrame.encode(opcode: 10, payload: frame.payload))
                case 10:
                    break
                default:
                    if frame.opcode != 0 { messageOpcode = frame.opcode }
                    message.append(frame.payload)
                    if frame.fin {
                        // Handled one at a time so that replies keep the client's request order.
                        if messageOpcode == 1 {
                            await handleClientText(String(decoding: message, as: UTF8.self))
                        } else {
                            try? await upstream.send(.data(message))
                        }
                        message = Data()
                    }
                }
            }
            guard let data = await receiveData(client) else { return }
            buffer.append(data)
        }
    }

    private func pumpUpstream() async {
        while true {
            guard let message = try? await upstream.receive() else { return }
            switch message {
            case .string(let text):
                noteAttachment(text)
                await sendData(client, WebSocketFrame.encode(opcode: 1, payload: Data(text.utf8)))
            case .data(let data):
                await sendData(client, WebSocketFrame.encode(opcode: 2, payload: data))
            @unknown default:
                return
            }
        }
    }

    // Page.bringToFront names a session, not a target, so remember which target each session belongs to.
    private func noteAttachment(_ text: String) {
        guard text.contains("\"Target.attachedToTarget\""),
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let params = json["params"] as? [String: Any], let sessionId = params["sessionId"] as? String,
              let info = params["targetInfo"] as? [String: Any], let targetId = info["targetId"] as? String else { return }
        lock.lock()
        sessionTargets[sessionId] = targetId
        lock.unlock()
    }

    private func target(forSession sessionId: String?) -> String? {
        guard let sessionId else { return pageTarget }
        lock.lock()
        defer { lock.unlock() }
        return sessionTargets[sessionId]
    }

    private func handleClientText(_ text: String) async {
        guard text.contains("Target.createTarget") || text.contains("Target.activateTarget") || text.contains("Page.bringToFront"),
              var json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let method = json["method"] as? String else {
            try? await upstream.send(.string(text))
            return
        }
        let params = json["params"] as? [String: Any] ?? [:]
        proxyLog("\(method) \(params)")

        switch method {
        case "Target.createTarget":
            json["params"] = await server.backgroundWindowParams(params)
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? await upstream.send(.string(String(decoding: data, as: UTF8.self)))
            } else {
                try? await upstream.send(.string(text))
            }
        case "Target.activateTarget", "Page.bringToFront":
            let targetId = method == "Target.activateTarget"
                ? params["targetId"] as? String
                : target(forSession: json["sessionId"] as? String)
            if let targetId, await !server.mustSelect(targetId: targetId) {
                proxyLog("  answered without Chrome")
                await replyEmpty(to: json)
            } else {
                proxyLog("  forwarded")
                try? await upstream.send(.string(text))
            }
        default:
            try? await upstream.send(.string(text))
        }
    }

    private func replyEmpty(to request: [String: Any]) async {
        var reply: [String: Any] = ["id": request["id"] ?? 0, "result": [String: Any]()]
        if let sessionId = request["sessionId"] { reply["sessionId"] = sessionId }
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        await sendData(client, WebSocketFrame.encode(opcode: 1, payload: data))
    }
}

// Default listen port is Chrome's + 10000. To make the proxy impossible to bypass, start Chrome on a
// private port and give the proxy the port everything already uses (see README).
func runProxy(chromePort: Int, listenPorts: [Int]) async {
    let ports = listenPorts.isEmpty ? [chromePort + proxyPortOffset] : listenPorts
    var servers: [ProxyServer] = []
    for port in ports {
        let server = ProxyServer(chromePort: chromePort, listenPort: port)
        do {
            try server.start()
        } catch {
            fail("can't start the proxy on \(port): \(error.localizedDescription)")
        }
        servers.append(server)
        print("Proxying 127.0.0.1:\(port) to Chrome on 127.0.0.1:\(chromePort)")
    }
    while true {
        try? await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}
