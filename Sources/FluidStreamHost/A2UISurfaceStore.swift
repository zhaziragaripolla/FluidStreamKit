public import Foundation
public import Observation

/// Something the host noticed and skipped, for logs and debugging. Never shown to the user.
public struct A2UIDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public let surfaceId: String?
    public let message: String
    public var description: String { surfaceId.map { "[\($0)] \(message)" } ?? message }
}

/// Holds every live surface and applies A2UI messages to them, in order.
///
/// SwiftUI views observe it. Feed it the output of an ``A2UILineDecoder``.
@MainActor
@Observable
public final class A2UISurfaceStore {
    public private(set) var surfaces: [String: A2UISurface] = [:]
    /// The most recent diagnostics, newest last, capped at ``maxDiagnostics``.
    public private(set) var diagnostics: [A2UIDiagnostic] = []

    /// Updates that arrived before their surface's `createSurface`, applied once it arrives.
    @ObservationIgnored private var early: [String: [A2UIMessage]] = [:]
    @ObservationIgnored public var maxDiagnostics = 100
    /// Per surface, how many early updates to hold before dropping the oldest.
    @ObservationIgnored public var maxEarlyMessages = 256

    public init() {}

    public func apply(_ output: Result<A2UIMessage, A2UIDecodingError>) {
        switch output {
        case .success(let message): apply(message)
        case .failure(let error): note(nil, error.description)
        }
    }

    public func apply(_ outputs: [Result<A2UIMessage, A2UIDecodingError>]) {
        for output in outputs { apply(output) }
    }

    public func apply(_ message: A2UIMessage) {
        let id = message.surfaceId
        switch message {
        case .createSurface(_, let catalogId, let theme, let sendDataModel):
            guard surfaces[id] == nil else { return note(id, "Surface already exists") }
            var surface = A2UISurface(id: id, catalogId: catalogId, theme: theme, sendDataModel: sendDataModel)
            for update in early.removeValue(forKey: id) ?? [] { apply(update, to: &surface) }
            surfaces[id] = surface
        case .deleteSurface:
            surfaces[id] = nil
            early[id] = nil
        case .updateComponents, .updateDataModel:
            guard var surface = surfaces[id] else {
                var queue = early[id, default: []]
                if queue.count >= maxEarlyMessages {
                    queue.removeFirst()
                    note(id, "Too many updates before createSurface; dropped the oldest")
                }
                queue.append(message)
                early[id] = queue
                return
            }
            apply(message, to: &surface)
            surfaces[id] = surface
        }
    }

    private func apply(_ message: A2UIMessage, to surface: inout A2UISurface) {
        switch message {
        case .updateComponents(_, let components):
            surface.upsert(components)
        case .updateDataModel(_, let path, let value):
            if !surface.updateData(path: path, value: value) {
                note(surface.id, "Couldn't write data at \(path)")
            }
        case .createSurface, .deleteSurface:
            break
        }
    }

    /// Writes user input back to the data model, as input components do on every change.
    public func setValue(_ value: JSONValue, at pointer: JSONPointer, surfaceId: String) {
        guard var surface = surfaces[surfaceId] else { return }
        if surface.dataModel.set(value, at: pointer) {
            surfaces[surfaceId] = surface
        } else {
            note(surfaceId, "Couldn't write input at \(pointer)")
        }
    }

    /// What tapping `node` should do, resolved against the current data model.
    public func action(for node: ResolvedNode, surfaceId: String, now: Date = Date()) -> A2UIAction? {
        guard let surface = surfaces[surfaceId], let component = node.component,
              let action = component["action"] else { return nil }
        func resolvedObject(_ value: JSONValue?) -> [String: JSONValue] {
            (value?.objectValue ?? [:]).mapValues { surface.resolve($0, scope: node.scope) ?? .null }
        }
        if let event = action["event"], let name = event["name"]?.stringValue {
            return .event(A2UIActionEvent(
                name: name, surfaceId: surfaceId, sourceComponentId: component.id,
                timestamp: now, context: resolvedObject(event["context"])))
        }
        if let call = action["functionCall"], let name = call["call"]?.stringValue {
            return .localFunction(name: name, args: resolvedObject(call["args"]))
        }
        return nil
    }

    private func note(_ surfaceId: String?, _ message: String) {
        diagnostics.append(A2UIDiagnostic(surfaceId: surfaceId, message: message))
        if diagnostics.count > maxDiagnostics { diagnostics.removeFirst(diagnostics.count - maxDiagnostics) }
    }
}

public enum A2UIAction: Sendable, Equatable {
    /// Send this to the agent.
    case event(A2UIActionEvent)
    /// Run on the device, such as `openUrl`. The app decides whether to honor it.
    case localFunction(name: String, args: [String: JSONValue])
}

/// A client-to-agent `action` message.
public struct A2UIActionEvent: Sendable, Equatable {
    public let name: String
    public let surfaceId: String
    public let sourceComponentId: String
    public let timestamp: Date
    public let context: [String: JSONValue]

    /// The message as JSON: `{"version": "v0.9.1", "action": {…}}`.
    public var json: JSONValue {
        [
            "version": .string(A2UIVersion.current),
            "action": [
                "name": .string(name),
                "surfaceId": .string(surfaceId),
                "sourceComponentId": .string(sourceComponentId),
                "timestamp": .string(timestamp.formatted(.iso8601)),
                "context": .object(context),
            ],
        ]
    }

    /// The message encoded as one JSON line (no trailing newline), with sorted keys.
    public func encoded() throws -> Data {
        try JSONValue.encoder.encode(json)
    }
}
