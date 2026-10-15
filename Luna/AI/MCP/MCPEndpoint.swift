import CryptoKit
import Foundation

/// One HTTP request as the listener parsed it. Header names are lowercased.
struct MCPHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var remoteIsLoopback: Bool
}

struct MCPHTTPResponse: Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> MCPHTTPResponse {
        var h = headers
        h["Content-Type"] = "application/json"
        return MCPHTTPResponse(status: status, headers: h, body: Data(value.jsonString().utf8))
    }

    static func text(_ status: Int, _ message: String, headers: [String: String] = [:]) -> MCPHTTPResponse {
        var h = headers
        h["Content-Type"] = "text/plain; charset=utf-8"
        return MCPHTTPResponse(status: status, headers: h, body: Data(message.utf8))
    }
}

enum MCPApproval: Equatable { case once, session, deny }

/// Asks the user whether an outside agent may run a mutating tool.
protocol MCPApproving: AnyObject {
    func approve(client: String, tool: String, detail: String) async -> MCPApproval
}

/// Transport-independent checks for the loopback MCP endpoint.
enum MCPGate {
    /// Compares SHA-256 digests byte by byte without early exit, so timing does not
    /// reveal how much of the token matched (or its length).
    static func tokensMatch(_ given: String, _ expected: String) -> Bool {
        guard !expected.isEmpty else { return false }
        let a = Array(SHA256.hash(data: Data(given.utf8)))
        let b = Array(SHA256.hash(data: Data(expected.utf8)))
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// `Host` must name this loopback listener; anything else may be DNS rebinding.
    static func hostAllowed(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// Browsers send `Origin`; only a loopback page (or no browser at all) may call us.
    static func originAllowed(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// Nil when the request may proceed; otherwise the rejection to send.
    static func reject(_ request: MCPHTTPRequest, port: UInt16, token: String?) -> MCPHTTPResponse? {
        guard request.remoteIsLoopback else { return .text(403, "Forbidden") }
        guard hostAllowed(request.headers["host"], port: port) else { return .text(403, "Invalid Host header") }
        guard originAllowed(request.headers["origin"]) else { return .text(403, "Invalid Origin") }
        guard request.path.split(separator: "?", maxSplits: 1).first.map(String.init) == "/mcp" else {
            return .text(404, "Not found")
        }
        let auth = request.headers["authorization"] ?? ""
        let given = auth.lowercased().hasPrefix("bearer ") ? String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces) : ""
        guard tokensMatch(given, token ?? "") else {
            return .text(401, "Unauthorized", headers: ["WWW-Authenticate": "Bearer"])
        }
        return nil
    }
}

/// MCP over streamable HTTP (JSON responses, no SSE stream) for the Luna toolbox.
/// Sessions are assigned at `initialize` (`Mcp-Session-Id`) and carry per-client approvals.
final class MCPEndpoint {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let latestVersion = "2025-11-25"
    static let maxSessions = 32

    final class Session {
        let id: String
        let clientName: String
        var protocolVersion: String
        var allowAll = false
        let created = Date()
        init(id: String, clientName: String, protocolVersion: String) {
            self.id = id
            self.clientName = clientName
            self.protocolVersion = protocolVersion
        }
    }

    let toolbox: LunaToolbox
    let port: () -> UInt16
    let token: () -> String?
    let isTrusted: () -> Bool
    weak var approver: MCPApproving?
    private(set) var sessions: [String: Session] = [:]

    nonisolated deinit {}

    init(toolbox: LunaToolbox, port: @escaping () -> UInt16, token: @escaping () -> String?,
         isTrusted: @escaping () -> Bool, approver: MCPApproving?) {
        self.toolbox = toolbox
        self.port = port
        self.token = token
        self.isTrusted = isTrusted
        self.approver = approver
    }

    func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        if let rejection = MCPGate.reject(request, port: port(), token: token()) { return rejection }
        if let version = request.headers["mcp-protocol-version"], !Self.supportedVersions.contains(version) {
            return .text(400, "Unsupported MCP-Protocol-Version")
        }
        switch request.method {
        case "POST":
            return await post(request)
        case "DELETE":
            guard let id = request.headers["mcp-session-id"] else { return .text(400, "Missing Mcp-Session-Id") }
            guard sessions.removeValue(forKey: id) != nil else { return .text(404, "Unknown session") }
            return MCPHTTPResponse(status: 200)
        default:
            // No server-initiated SSE stream is offered.
            return .text(405, "Method not allowed", headers: ["Allow": "POST, DELETE"])
        }
    }

    // MARK: JSON-RPC

    private func post(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        if let type = request.headers["content-type"], !type.lowercased().contains("application/json") {
            return .text(415, "Content-Type must be application/json")
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body) else {
            return .json(Self.error(id: .null, code: -32700, "Parse error"), status: 400)
        }
        guard case .object(let object) = message else {
            return .json(Self.error(id: .null, code: -32600, "Expected one JSON-RPC message (batches are not supported)"), status: 400)
        }
        guard object["jsonrpc"] == "2.0" else {
            return .json(Self.error(id: object["id"] ?? .null, code: -32600, "jsonrpc must be \"2.0\""), status: 400)
        }
        let method = object["method"]?.stringValue
        let id = object["id"]

        // Responses and notifications from the client: accepted, nothing to return.
        if method == nil || id == nil {
            if method == nil, object["result"] == nil, object["error"] == nil {
                return .json(Self.error(id: id ?? .null, code: -32600, "Invalid request"), status: 400)
            }
            if let missing = sessionProblem(request) { return missing }
            return MCPHTTPResponse(status: 202)
        }
        guard let id, Self.isValidId(id), let method else {
            return .json(Self.error(id: .null, code: -32600, "Invalid request id"), status: 400)
        }

        if method == "initialize" {
            return initialize(id: id, params: object["params"])
        }
        if let problem = sessionProblem(request) { return problem }
        let session = sessions[request.headers["mcp-session-id"] ?? ""]
        let params = object["params"]

        switch method {
        case "ping":
            return .json(Self.result(id: id, .object([:])))
        case "tools/list":
            let tools = toolbox.tools.map { tool -> JSONValue in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "annotations": .object(["readOnlyHint": .bool(!tool.mutates), "openWorldHint": .bool(true)]),
                ])
            }
            return .json(Self.result(id: id, .object(["tools": .array(tools)])))
        case "tools/call":
            return .json(await callTool(id: id, params: params, session: session))
        default:
            return .json(Self.error(id: id, code: -32601, "Method not found: \(method)"))
        }
    }

    private func initialize(id: JSONValue, params: JSONValue?) -> MCPHTTPResponse {
        let requested = params?["protocolVersion"]?.stringValue ?? ""
        let version = Self.supportedVersions.contains(requested) ? requested : Self.latestVersion
        let client = params?["clientInfo"]?["name"]?.stringValue ?? "An agent"
        if sessions.count >= Self.maxSessions, let oldest = sessions.values.min(by: { $0.created < $1.created }) {
            sessions.removeValue(forKey: oldest.id)
        }
        let session = Session(id: UUID().uuidString, clientName: String(client.prefix(60)), protocolVersion: version)
        sessions[session.id] = session
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let result: JSONValue = .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object(["name": "luna", "title": "Luna browser", "version": .string(appVersion)]),
            "instructions": "Drive the user's Luna browser tabs. Call snapshot to get element ids, then click/type/select by id; ids expire when the page changes. Mutating tools may wait for the user to approve in Luna.",
        ])
        return .json(Self.result(id: id, result), headers: ["Mcp-Session-Id": session.id])
    }

    private func callTool(id: JSONValue, params: JSONValue?, session: Session?) async -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            return Self.error(id: id, code: -32602, "tools/call needs a tool name")
        }
        guard let tool = toolbox.tool(named: name) else {
            return Self.error(id: id, code: -32602, "Unknown tool: \(name)")
        }
        let rawArguments = params?["arguments"] ?? .object([:])
        guard case .object(let arguments) = rawArguments else {
            return Self.error(id: id, code: -32602, "arguments must be an object")
        }
        if tool.mutates, !isTrusted(), session?.allowAll != true {
            // Don't ask the user about a call that would be rejected anyway.
            do { try tool.validate(arguments) } catch {
                return Self.result(id: id, Self.toolResult(LunaToolResult(text: error.localizedDescription, isError: true)))
            }
            let detail = AgentRedaction.redact(Self.summary(arguments))
            let decision = await approver?.approve(client: session?.clientName ?? "An agent", tool: name, detail: detail) ?? .deny
            switch decision {
            case .deny:
                return Self.result(id: id, Self.toolResult(LunaToolResult(text: "The user declined this action in Luna.", isError: true)))
            case .session:
                session?.allowAll = true
            case .once:
                break
            }
        }
        do {
            return Self.result(id: id, Self.toolResult(try await toolbox.call(name, arguments: arguments)))
        } catch {
            return Self.error(id: id, code: -32602, error.localizedDescription)
        }
    }

    /// Nil when the request carries a live session id.
    private func sessionProblem(_ request: MCPHTTPRequest) -> MCPHTTPResponse? {
        guard let id = request.headers["mcp-session-id"] else { return .text(400, "Missing Mcp-Session-Id; call initialize first") }
        guard sessions[id] != nil else { return .text(404, "Unknown session; initialize again") }
        return nil
    }

    // MARK: Helpers

    static func isValidId(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .number: return true
        default: return false
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    static func toolResult(_ r: LunaToolResult) -> JSONValue {
        .object(["content": .array([.object(["type": "text", "text": .string(r.text)])]), "isError": .bool(r.isError)])
    }

    /// Short one-line argument summary for the approval prompt.
    static func summary(_ arguments: [String: JSONValue]) -> String {
        let parts = arguments.keys.sorted().map { key -> String in
            let value = arguments[key].map { $0.stringValue ?? $0.jsonString() } ?? ""
            return "\(key): \(value.count > 120 ? String(value.prefix(120)) + "…" : value)"
        }
        return parts.joined(separator: ", ")
    }
}
