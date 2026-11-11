import Foundation
import Testing
@testable import FluidStreamHost
@testable import FluidStreamHostUI

/// Google's official A2UI 1.0 basic-catalog examples, run through the host end to end.
@Suite("A2UI 1.0 conformance")
@MainActor
struct ConformanceTests {
    nonisolated static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/A2UI-1.0-basic-examples")

    nonisolated static var exampleFiles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Properties that hold structure (ids, templates, actions, checks), not values to display.
    nonisolated static let structural: Set<String> = ["child", "children", "tabs", "trigger", "content", "action", "@checks", "@metadata", "@catalogId"]

    @Test func allExamplesArePresent() {
        #expect(Self.exampleFiles.count >= 40)
    }

    @Test(arguments: exampleFiles)
    func exampleRendersCompletely(_ file: URL) throws {
        let example = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        let messages = try #require(example["messages"]?.arrayValue)
        let store = A2UISurfaceStore()
        var outgoing: [A2UIRendererMessage] = []
        store.onMessageToAgent = { outgoing.append($0) }
        for message in messages {
            store.apply(try A2UIMessage.decode(message))
        }
        #expect(store.diagnostics.isEmpty, "\(file.lastPathComponent): \(store.diagnostics)")
        #expect(outgoing.isEmpty)
        #expect(!store.surfaces.isEmpty)

        let basic = A2UICatalog.basic
        for surface in store.surfaces.values {
            #expect(basic.answers(to: try #require(surface.catalogId)))
            let tree = try #require(surface.resolvedTree(), "\(file.lastPathComponent): no root")
            var problems: [String] = []
            func visit(_ node: ResolvedNode) {
                switch node.state {
                case .pending: problems.append("\(node.id) never arrived")
                case .invalid(let reason): problems.append("\(node.id): \(reason)")
                case .ready(let component):
                    if !basic.componentTypes.contains(component.type) { problems.append("unknown type \(component.type)") }
                    for (key, value) in component.properties where !Self.structural.contains(key) {
                        if case .failure(let error) = surface.evaluate(value, scope: node.scope, index: node.index) {
                            problems.append("\(node.id).\(key): \(error)")
                        }
                    }
                    for (key, value) in component["action"]?["event"]?["context"]?.objectValue ?? [:] {
                        if case .failure(let error) = surface.evaluate(value, scope: node.scope, index: node.index) {
                            problems.append("\(node.id).action.\(key): \(error)")
                        }
                    }
                    for rule in component.checks {
                        if let condition = rule["condition"],
                           case .failure(let error) = surface.evaluate(condition, scope: node.scope, index: node.index) {
                            problems.append("\(node.id).@checks: \(error)")
                        }
                    }
                }
                node.children.forEach(visit)
            }
            visit(tree)
            #expect(problems.isEmpty, "\(file.lastPathComponent): \(problems)")
        }
    }
}
