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
/// SwiftUI views observe it. Feed it the output of an ``A2UILineDecoder``, and send what
/// ``onMessageToAgent`` hands you (function responses and errors) back to the agent.
@MainActor
@Observable
public final class A2UISurfaceStore {
    public private(set) var surfaces: [String: A2UISurface] = [:]
    /// The most recent diagnostics, newest last, capped at ``maxDiagnostics``.
    public private(set) var diagnostics: [A2UIDiagnostic] = []

    /// The functions this renderer runs, for bindings, checks, actions and `callRendererFunction`.
    @ObservationIgnored public var functions: A2UIFunctionRegistry
    /// Messages the store sends on its own: answers to `callRendererFunction`, and errors such
    /// as a duplicate `createSurface`. Deliver them to the agent.
    @ObservationIgnored public var onMessageToAgent: (@MainActor (A2UIRendererMessage) -> Void)?
    /// The agent's answers to `callAgentFunction` calls made from actions.
    @ObservationIgnored public var onAgentFunctionResponse: (@MainActor (A2UIFunctionResponse) -> Void)?

    /// Updates that arrived before their surface's `createSurface`, applied once it arrives.
    @ObservationIgnored private var early: [String: [A2UIMessage]] = [:]
    @ObservationIgnored private var deleted: Set<String> = []
    @ObservationIgnored public var maxDiagnostics = 100
    /// Per surface, how many early updates to hold before dropping the oldest.
    @ObservationIgnored public var maxEarlyMessages = 256

    public init(functions: A2UIFunctionRegistry = .basic) {
        self.functions = functions
    }

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
        switch message {
        case .createSurface(let definition):
            let id = definition.surfaceId
            guard surfaces[id] == nil else {
                return report(.error(A2UIRendererError(
                    code: "INTEGRITY_ERROR", message: "Surface '\(id)' already exists", surfaceId: id)))
            }
            deleted.remove(id)
            var surface = A2UISurface(definition)
            for update in early.removeValue(forKey: id) ?? [] { apply(update, to: &surface) }
            surfaces[id] = surface
        case .deleteSurface(let id):
            surfaces[id] = nil
            early[id] = nil
            deleted.insert(id)
        case .updateComponents(let id, _), .updateDataModel(let id, _, _):
            guard var surface = surfaces[id] else {
                guard !deleted.contains(id) else { return note(id, "Update for a deleted surface") }
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
        case .callRendererFunction(let callId, let surfaceId, let call):
            let response = A2UIFunctionResponse(
                functionCallId: callId, result: runForAgent(call, surfaceId: surfaceId))
            onMessageToAgent?(.rendererFunctionResponse(response))
        case .agentFunctionResponse(let response):
            if case .failure(let error) = response.result {
                note(nil, "Agent function \(response.functionCallId) failed: \(error)")
            }
            onAgentFunctionResponse?(response)
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
        default:
            break
        }
    }

    /// Runs a function the agent asked for, enforcing who may call it.
    private func runForAgent(_ call: A2UIFunctionCall, surfaceId: String?) -> Result<JSONValue, A2UIFunctionError> {
        guard let definition = functions[call.name] else {
            return .failure(.invalidCall("Function '\(call.name)' isn't registered"))
        }
        guard definition.allowedCallers != .rendererOnly else {
            return .failure(.invalidCall("Function '\(call.name)' cannot be called by agent (allowedCallers is rendererOnly)."))
        }
        let surface: A2UISurface?
        if let surfaceId {
            guard let s = surfaces[surfaceId] else { return .failure(.invalidCall("No surface '\(surfaceId)'")) }
            surface = s
        } else {
            surface = nil
        }
        let evaluator = A2UIEvaluator(dataModel: surface?.dataModel ?? .object([:]), functions: functions)
        do throws(A2UIFunctionError) {
            switch definition.body {
            case .pure:
                return .success(try evaluator.call(call))
            case .effect:
                return .failure(.invalidCall("Function '\(call.name)' has side effects and needs a user gesture"))
            }
        } catch {
            return .failure(error)
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
    ///
    /// - An `event` becomes an `action` for the agent.
    /// - A `functionCall` this renderer implements runs here: a pure one just runs, an effect
    ///   such as `openUrl` is checked and handed to the app. One it doesn't implement becomes a
    ///   `callAgentFunction` for the agent.
    /// - Nothing happens while one of the component's `@checks` fails.
    public func action(for node: ResolvedNode, surfaceId: String, now: Date = Date()) -> A2UIAction? {
        guard let surface = surfaces[surfaceId], let component = node.component,
              let action = component["action"] else { return nil }
        guard surface.failingChecks(of: component, scope: node.scope, index: node.index, functions: functions).isEmpty else {
            return nil
        }
        let evaluator = surface.evaluator(scope: node.scope, index: node.index, functions: functions, userActivated: true)
        func fail(_ error: A2UIFunctionError) -> A2UIAction {
            .error(A2UIRendererError(code: error.code, message: error.message, surfaceId: surfaceId))
        }
        if let event = action["event"], let name = event["name"]?.stringValue {
            var context: [String: JSONValue] = [:]
            var userMessage: String?
            do throws(A2UIFunctionError) {
                for (key, value) in event["context"]?.objectValue ?? [:] { context[key] = try evaluator.evaluate(value) }
                if let message = event["userMessage"] { userMessage = try evaluator.evaluate(message).displayString }
            } catch {
                return fail(error)
            }
            return .event(A2UIActionEvent(
                name: name, surfaceId: surfaceId, sourceComponentId: component.id, timestamp: now,
                context: context, userMessage: userMessage, protocolVersion: surface.protocolVersion))
        }
        if let call = A2UIFunctionCall(action["functionCall"]) {
            if !call.name.hasPrefix("@"), functions[call.name] == nil {
                // Not implemented here: the agent runs it.
                var resolved = call
                do throws(A2UIFunctionError) {
                    resolved.args = try evaluator.arguments(of: call).values
                } catch {
                    return fail(error)
                }
                resolved.catalogId = call.catalogId ?? component.catalogId ?? surface.catalogId
                return .callAgentFunction(A2UIAgentFunctionCall(
                    surfaceId: surfaceId, functionCallId: UUID().uuidString, call: resolved))
            }
            do throws(A2UIFunctionError) {
                if let definition = functions[call.name], case .effect(let validate) = definition.body {
                    guard definition.allowedCallers != .agentOnly else {
                        throw .invalidCall("Function '\(call.name)' can only be called by the agent")
                    }
                    return .localFunction(name: call.name, args: try validate(try evaluator.arguments(of: call)))
                }
                _ = try evaluator.call(call)
                return nil
            } catch {
                return .error(A2UIRendererError(
                    code: error.code == "EXPRESSION_ERROR" ? error.code : "EXECUTION_ERROR",
                    message: error.message, surfaceId: surfaceId))
            }
        }
        return nil
    }

    private func report(_ message: A2UIRendererMessage) {
        if case .error(let e) = message { note(e.surfaceId, "\(e.code): \(e.message)") }
        onMessageToAgent?(message)
    }

    private func note(_ surfaceId: String?, _ message: String) {
        diagnostics.append(A2UIDiagnostic(surfaceId: surfaceId, message: message))
        if diagnostics.count > maxDiagnostics { diagnostics.removeFirst(diagnostics.count - maxDiagnostics) }
    }
}

/// What a tap asks the app to do.
public enum A2UIAction: Sendable, Equatable {
    /// Send this `action` to the agent.
    case event(A2UIActionEvent)
    /// Send this `callAgentFunction` to the agent, and feed its `agentFunctionResponse` back
    /// into the store.
    case callAgentFunction(A2UIAgentFunctionCall)
    /// Run a side effect on the device, such as `openUrl`. Its arguments are already checked;
    /// the app decides whether to honor it.
    case localFunction(name: String, args: [String: JSONValue])
    /// Send this error to the agent.
    case error(A2UIRendererError)

    /// The message to send to the agent, if this action has one.
    public var messageToAgent: A2UIRendererMessage? {
        switch self {
        case .event(let e): return .action(e)
        case .callAgentFunction(let c): return .callAgentFunction(c)
        case .error(let e): return .error(e)
        case .localFunction: return nil
        }
    }
}
