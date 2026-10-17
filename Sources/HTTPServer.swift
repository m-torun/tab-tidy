import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    var status = 200
    var contentType = "application/json"
    var body = Data()

    static func json<T: Encodable>(_ value: T) -> HTTPResponse {
        HTTPResponse(body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(text.utf8))
    }

    static func status(_ code: Int) -> HTTPResponse {
        HTTPResponse(status: code, contentType: "text/plain", body: Data("\(code)\n".utf8))
    }
}

/// A minimal HTTP/1.1 server on 127.0.0.1 for the plan page: one request per
/// connection, handled on the main queue.
final class HTTPServer {
    private let listener: NWListener
    private let handler: (HTTPRequest) -> HTTPResponse

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(handler: @escaping (HTTPRequest) -> HTTPResponse) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start(onFailure: @escaping (Error) -> Void) {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { onFailure(error) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receive(on: connection, buffer: Data())
        }
        listener.start(queue: .main)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.send(self.handler(request), on: connection)
            } else if done || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// The request, or nil until all of it has arrived.
    private static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: Data(body.prefix(length)))
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let head = [
            "HTTP/1.1 \(response.status) \(response.status < 400 ? "OK" : "Error")",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Cache-Control: no-store",
            // Tab titles are untrusted text; the page may load nothing from anywhere else.
            "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
