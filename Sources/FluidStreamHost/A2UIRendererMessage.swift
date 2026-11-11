public import Foundation

/// A renderer-to-agent A2UI message.
public enum A2UIRendererMessage: Sendable, Equatable {
    case action(A2UIActionEvent)
    case callAgentFunction(A2UIAgentFunctionCall)
    case rendererFunctionResponse(A2UIFunctionResponse)
    case error(A2UIRendererError)

    /// The message as JSON, with its `version`.
    public var json: JSONValue {
        switch self {
        case .action(let e): return e.json
        case .callAgentFunction(let c):
            return ["version": .string(A2UIVersion.current), "callAgentFunction": c.body]
        case .rendererFunctionResponse(let r):
            return ["version": .string(A2UIVersion.current), "rendererFunctionResponse": r.json]
        case .error(let e):
            return ["version": .string(A2UIVersion.current), "error": e.json]
        }
    }

    /// One JSON line (no trailing newline), with sorted keys.
    public func encoded() throws -> Data {
        try JSONValue.encoder.encode(json)
    }
}

/// A renderer-to-agent `action` message: the user did something the agent should hear about.
public struct A2UIActionEvent: Sendable, Equatable {
    public let name: String
    public let surfaceId: String
    public let sourceComponentId: String
    public let timestamp: Date
    public let context: [String: JSONValue]
    /// A human-readable description of what the user did, if the component gave one.
    public let userMessage: String?
    /// The version to answer in: the one the agent used for the surface.
    public let protocolVersion: String

    public init(name: String, surfaceId: String, sourceComponentId: String, timestamp: Date,
                context: [String: JSONValue], userMessage: String? = nil, protocolVersion: String = A2UIVersion.current) {
        self.name = name
        self.surfaceId = surfaceId
        self.sourceComponentId = sourceComponentId
        self.timestamp = timestamp
        self.context = context
        self.userMessage = userMessage
        self.protocolVersion = protocolVersion
    }

    /// The message as JSON: `{"version": "1.0", "action": {…}}`.
    public var json: JSONValue {
        var action: [String: JSONValue] = [
            "name": .string(name),
            "surfaceId": .string(surfaceId),
            "sourceComponentId": .string(sourceComponentId),
            "timestamp": .string(timestamp.formatted(.iso8601)),
            "context": .object(context),
        ]
        if let userMessage { action["userMessage"] = .string(userMessage) }
        return ["version": .string(protocolVersion), "action": .object(action)]
    }

    /// The message encoded as one JSON line (no trailing newline), with sorted keys.
    public func encoded() throws -> Data {
        try JSONValue.encoder.encode(json)
    }
}

/// A `callAgentFunction` message: the renderer asks the agent to run a function it doesn't
/// implement itself. Arguments are already resolved against the data model.
public struct A2UIAgentFunctionCall: Sendable, Equatable {
    public let surfaceId: String
    public let functionCallId: String
    public let call: A2UIFunctionCall

    public init(surfaceId: String, functionCallId: String, call: A2UIFunctionCall) {
        self.surfaceId = surfaceId
        self.functionCallId = functionCallId
        self.call = call
    }

    var body: JSONValue {
        ["surfaceId": .string(surfaceId), "functionCallId": .string(functionCallId), "callFunction": call.json]
    }
}

/// A renderer-side error, reported to the agent.
public struct A2UIRendererError: Sendable, Equatable, Error {
    /// `VALIDATION_FAILED`, `INTEGRITY_ERROR`, `INVALID_FUNCTION_CALL`, `EXPRESSION_ERROR`,
    /// `EXECUTION_ERROR`, `UNKNOWN_FUNCTION`, `UNALLOWED_PARENT` or `UNALLOWED_CHILD`.
    public let code: String
    public let message: String
    public let surfaceId: String?
    public let functionCallId: String?
    /// For `VALIDATION_FAILED`: a JSON Pointer to the field that failed.
    public let path: String?

    public init(code: String, message: String, surfaceId: String? = nil, functionCallId: String? = nil, path: String? = nil) {
        self.code = code
        self.message = message
        self.surfaceId = surfaceId
        self.functionCallId = functionCallId
        self.path = path
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
        // Exactly one of surfaceId and functionCallId.
        if let functionCallId { o["functionCallId"] = .string(functionCallId) } else if let surfaceId { o["surfaceId"] = .string(surfaceId) }
        if let path { o["path"] = .string(path) }
        return .object(o)
    }
}
