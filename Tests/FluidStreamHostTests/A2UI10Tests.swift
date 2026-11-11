import Foundation
import Testing
@testable import FluidStreamHost
@testable import FluidStreamHostUI

private func decode(_ line: String) throws -> A2UIMessage {
    try A2UIMessage.decode(line: Data(line.utf8))
}

private let enUS = Locale(identifier: "en_US")

@Suite("A2UI 1.0 messages")
struct A2UI10MessageTests {
    @Test func createSurfaceCarriesInlineComponentsAndData() throws {
        let message = try decode(##"{"version":"1.0","createSurface":{"surfaceId":"s","catalogId":"c","components":[{"id":"root","component":"Text","text":{"@path":"/greeting"}}],"dataModel":{"greeting":"Hi"},"theme":{"primaryColor":"#000"}}}"##)
        guard case .createSurface(let definition) = message else { Issue.record("wrong message"); return }
        #expect(definition.protocolVersion == "1.0")
        #expect(definition.components.map(\.id) == ["root"])
        let surface = A2UISurface(definition)
        #expect(surface.string("text", of: try #require(surface.components["root"])) == "Hi")
    }

    @Test func catalogIdIsOptionalIn10() throws {
        guard case .createSurface(let d) = try decode(#"{"version":"1.0","createSurface":{"surfaceId":"s"}}"#) else {
            Issue.record("wrong message"); return
        }
        #expect(d.catalogId == nil)
    }

    @Test func updateDataModelNeedsAValueAndNullDeletes() throws {
        #expect(throws: A2UIDecodingError.missingField("value", message: "updateDataModel")) {
            try decode(#"{"version":"1.0","updateDataModel":{"surfaceId":"s","path":"/a"}}"#)
        }
        var surface = A2UISurface(id: "s", catalogId: "c")
        surface.updateData(path: "/a", value: ["b": 1, "c": 2])
        #expect(try decode(#"{"version":"1.0","updateDataModel":{"surfaceId":"s","path":"/a/b","value":null}}"#)
                == .updateDataModel(surfaceId: "s", path: "/a/b", value: .null))
        surface.updateData(path: "/a/b", value: .null)
        #expect(surface.dataModel == ["a": ["c": 2]])
        surface.updateData(path: "/", value: .null)
        #expect(surface.dataModel == [:])
    }

    @Test func versionStringHasNoVPrefix() {
        #expect(throws: A2UIDecodingError.unsupportedVersion("v1.0")) {
            try decode(#"{"version":"v1.0","deleteSurface":{"surfaceId":"s"}}"#)
        }
    }

    @Test func functionCallMessagesDecode() throws {
        #expect(try decode(#"{"version":"1.0","callRendererFunction":{"functionCallId":"f1","surfaceId":"s","callFunction":{"@call":"formatNumber","catalogId":"c","args":{"value":3}}}}"#)
                == .callRendererFunction(functionCallId: "f1", surfaceId: "s",
                                         call: A2UIFunctionCall(name: "formatNumber", catalogId: "c", args: ["value": 3])))
        // catalogId is required on callRendererFunction.
        #expect(throws: A2UIDecodingError.missingField("callFunction.catalogId", message: "callRendererFunction")) {
            try decode(#"{"version":"1.0","callRendererFunction":{"functionCallId":"f1","callFunction":{"@call":"x"}}}"#)
        }
        #expect(try decode(#"{"version":"1.0","agentFunctionResponse":{"functionCallId":"f1","error":{"code":"UNKNOWN_FUNCTION","message":"no"}}}"#)
                == .agentFunctionResponse(A2UIFunctionResponse(functionCallId: "f1", result: .failure(A2UIFunctionError("UNKNOWN_FUNCTION", "no")))))
    }

    @Test func rendererMessagesEncodeTo10Shapes() throws {
        let call = A2UIRendererMessage.callAgentFunction(A2UIAgentFunctionCall(
            surfaceId: "s", functionCallId: "f1", call: A2UIFunctionCall(name: "checkStock", catalogId: "c", args: ["sku": "A1"])))
        #expect(String(decoding: try call.encoded(), as: UTF8.self)
                == #"{"callAgentFunction":{"callFunction":{"@call":"checkStock","args":{"sku":"A1"},"catalogId":"c"},"functionCallId":"f1","surfaceId":"s"},"version":"1.0"}"#)
        let error = A2UIRendererMessage.error(A2UIRendererError(code: "INTEGRITY_ERROR", message: "dup", surfaceId: "s"))
        #expect(String(decoding: try error.encoded(), as: UTF8.self)
                == #"{"error":{"code":"INTEGRITY_ERROR","message":"dup","surfaceId":"s"},"version":"1.0"}"#)
        let response = A2UIRendererMessage.rendererFunctionResponse(A2UIFunctionResponse(functionCallId: "f2", result: .success("ok")))
        #expect(String(decoding: try response.encoded(), as: UTF8.self)
                == #"{"rendererFunctionResponse":{"functionCallId":"f2","value":"ok"},"version":"1.0"}"#)
    }
}

@Suite("Legacy v0.9 upgrade")
struct LegacyUpgradeTests {
    @Test func bindingsCallsAndChecksMoveTo10Keys() throws {
        let message = try decode(#"{"version":"v0.9.1","updateComponents":{"surfaceId":"s","components":[{"id":"f","component":"TextField","value":{"path":"/email"},"validationRegexp":"^.+@.+$","checks":[{"condition":{"call":"required","args":{"value":{"path":"/email"}},"returnType":"boolean"},"message":"Required"}],"accessibility":{"label":"Email"},"fallback":"plain","minVersion":2,"children":{"componentId":"row","path":"/items"}}]}}"#)
        guard case .updateComponents(_, let components) = message, let f = components.first else { Issue.record("wrong"); return }
        #expect(f["value"] == ["@path": "/email"])
        #expect(f["children"] == ["componentId": "row", "path": "/items"])   // templates keep `path`
        #expect(f.accessibility == ["label": "Email"])
        #expect(f.checks.count == 2)
        #expect(f.checks.first?["condition"] == ["@call": "required", "args": ["value": ["@path": "/email"]]])
        #expect(f.checks.last?["condition"]?["@call"] == "regex")
        #expect(f.fallbackId == "plain")
        #expect(f.minimumVersion == 2)
        #expect(f["validationRegexp"] == nil && f["checks"] == nil)
    }

    @Test @MainActor func legacySurfacesAnswerInTheirOwnVersion() throws {
        let store = store(feeding: profileStream)
        #expect(store.surfaces["user_profile_card"]?.protocolVersion == "v0.9.1")
    }
}

@Suite("Dynamic values and functions")
struct FunctionTests {
    func evaluate(_ value: JSONValue, data: JSONValue = [:], index: Int? = nil, scope: JSONPointer = .root) throws -> JSONValue {
        try A2UIEvaluator(dataModel: data, scope: scope, index: index, locale: enUS).evaluate(value)
    }

    @Test func escapedAndReservedKeys() throws {
        #expect(try evaluate(["@@path": "/x", "a": 1]) == ["@path": "/x", "a": 1])
        #expect(throws: A2UIFunctionError.self) { try evaluate(["@weird": 1]) }
        #expect(try evaluate(["path": "/x"]) == ["path": "/x"])   // plain data, not a binding, in 1.0
        #expect(try evaluate(["@path": "/missing"]) == .null)
    }

    @Test func formatStringInterpolatesPathsAndNestedCalls() throws {
        let data: JSONValue = ["name": "Ada", "reviewCount": 1234, "total": 49.5, "start": "2026-11-14T09:30:00"]
        func format(_ template: String) throws -> String {
            try evaluate(["@call": "formatString", "args": ["value": .string(template)]], data: data).displayString
        }
        #expect(try format("Hello ${/name}!") == "Hello Ada!")
        #expect(try format(#"(${formatNumber(value: ${/reviewCount})} ${pluralize(value: ${/reviewCount}, one: 'review', other: 'reviews')})"#)
                == "(1,234 reviews)")
        #expect(try format("${formatCurrency(value: ${/total}, currency: 'USD')}/year") == "$49.50/year")
        #expect(try format("${formatDate(value: ${/start}, format: 'yyyy-MM-dd HH:mm')}") == "2026-11-14 09:30")
        #expect(try format(#"Literal \${not} and ${'quoted'} ${true} ${42}"#) == "Literal ${not} and quoted true 42")
        #expect(throws: A2UIFunctionError.self) { try format("${/name") }
    }

    @Test func pluralizeUsesTheLocalesRules() throws {
        let args: [String: JSONValue] = ["one": "item", "few": "items(few)", "many": "items(many)", "other": "items"]
        func plural(_ n: Double, _ locale: String) throws -> String {
            var a = args
            a["value"] = .number(n)
            return try A2UIEvaluator(dataModel: [:], locale: Locale(identifier: locale))
                .call(A2UIFunctionCall(name: "pluralize", args: a)).displayString
        }
        #expect(try plural(1, "en_US") == "item")
        #expect(try plural(2, "en_US") == "items")
        #expect(try plural(3, "ru_RU") == "items(few)")
        #expect(try plural(5, "ru_RU") == "items(many)")
        #expect(try plural(21, "ru_RU") == "item")
    }

    @Test func indexWorksOnlyInTemplates() throws {
        #expect(try evaluate(["@call": "@index", "args": ["offset": 1]], index: 2) == 3)
        #expect(throws: A2UIFunctionError.execution("@index is only available inside a list template")) {
            try evaluate(["@call": "@index"])
        }
    }

    @Test func validationFunctionsReturnValidationResults() throws {
        func valid(_ call: JSONValue) throws -> Bool { A2UIEvaluator.truthiness(try evaluate(call)) }
        #expect(try valid(["@call": "required", "args": ["value": "x"]]))
        #expect(try !valid(["@call": "required", "args": ["value": ""]]))
        #expect(try !valid(["@call": "required", "args": ["value": []]]))
        #expect(try valid(["@call": "email", "args": ["value": "ada@example.com"]]))
        #expect(try !valid(["@call": "email", "args": ["value": "ada@example"]]))
        #expect(try valid(["@call": "length", "args": ["value": "abcd", "min": 2, "max": 4]]))
        #expect(try !valid(["@call": "numeric", "args": ["value": "12", "max": 10]]))
        #expect(try valid(["@call": "and", "args": ["values": [true, ["@call": "not", "args": ["value": false]]]]]))
        #expect(try evaluate(["@call": "required", "args": ["value": "x"]]) == ["valid": true])
    }

    @Test func regexDialectAndSafety() throws {
        func matches(_ value: String, _ pattern: String) throws -> Bool {
            A2UIEvaluator.truthiness(try evaluate(["@call": "regex", "args": ["value": .string(value), "pattern": .string(pattern)]]))
        }
        #expect(try matches("12345", #"^\d{5}$"#))
        #expect(try !matches("١٢٣٤٥", #"^\d{5}$"#))   // \d is ASCII-only
        for unsafe in [#"(a+)+$"#, #"(a*)*"#, #"(\w+){2,}"#, #"(a)\1"#, #"(?<=a)b"#, #"(?<n>a)"#, #"\p{L}"#, #"(?i)a"#,
                       String(repeating: "a", count: 300)] {
            #expect(throws: A2UIFunctionError.self, "\(unsafe)") { try matches("aaaa", unsafe) }
        }
        #expect(try matches("aaa", #"(?:ab|cd)+|a{1,3}"#))
        #expect(try !matches(String(repeating: "a", count: 5_000), "a"))   // value cap
    }

    @Test func openUrlNeedsAUserGesture() throws {
        #expect(throws: A2UIFunctionError.self) { try evaluate(["@call": "openUrl", "args": ["url": "https://a2ui.org"]]) }
    }

    @Test func callsCantNestForever() {
        var value: JSONValue = "x"
        for _ in 0..<100 { value = ["@call": "not", "args": ["value": value]] }
        #expect(throws: A2UIFunctionError.self) { try evaluate(value) }
    }
}

@Suite("Actions, checks and function calls")
@MainActor
struct ActionTests {
    func surfaceStore(_ components: [A2UIComponent], data: JSONValue = [:]) -> A2UISurfaceStore {
        let store = A2UISurfaceStore()
        store.apply(.createSurface(A2UISurfaceDefinition(surfaceId: "s", catalogId: "app", components: components, dataModel: data)))
        return store
    }

    func tap(_ store: A2UISurfaceStore) throws -> A2UIAction? {
        store.action(for: try #require(store.surfaces["s"]?.resolvedTree()), surfaceId: "s")
    }

    @Test func failingChecksBlockTheAction() throws {
        let store = surfaceStore([A2UIComponent(id: "root", type: "Button", properties: [
            "child": "label",
            "@checks": [["condition": ["@call": "email", "args": ["value": ["@path": "/email"]]], "message": "Enter an email"]],
            "action": ["event": ["name": "subscribe", "userMessage": ["@call": "formatString", "args": ["value": "Subscribe ${/email}"]],
                                 "context": ["email": ["@path": "/email"]]]],
        ])], data: ["email": "nope"])
        let surface = try #require(store.surfaces["s"])
        #expect(surface.failingChecks(of: try #require(surface.components["root"])).map(\.message) == ["Enter an email"])
        #expect(try tap(store) == nil)
        store.setValue("ada@example.com", at: JSONPointer("/email")!, surfaceId: "s")
        guard case .event(let event)? = try tap(store) else { Issue.record("expected an event"); return }
        #expect(event.context == ["email": "ada@example.com"])
        #expect(event.userMessage == "Subscribe ada@example.com")
    }

    @Test func openUrlRunsOnTapAndRejectsUnsafeURLs() throws {
        func action(_ url: String) throws -> A2UIAction? {
            try tap(surfaceStore([A2UIComponent(id: "root", type: "Button", properties: [
                "action": ["functionCall": ["@call": "openUrl", "args": ["url": .string(url)]]]])]))
        }
        #expect(try action("https://a2ui.org/help") == .localFunction(name: "openUrl", args: ["url": "https://a2ui.org/help"]))
        guard case .error(let error)? = try action("javascript:alert(1)") else { Issue.record("expected an error"); return }
        #expect(error.code == "EXECUTION_ERROR")
    }

    @Test func unknownFunctionsGoToTheAgentWithResolvedArguments() throws {
        let store = surfaceStore([A2UIComponent(id: "root", type: "Button", properties: [
            "action": ["functionCall": ["@call": "reserveTable", "args": ["size": ["@path": "/size"]]]]])], data: ["size": 4])
        guard case .callAgentFunction(let call)? = try tap(store) else { Issue.record("expected an agent call"); return }
        #expect(call.call == A2UIFunctionCall(name: "reserveTable", catalogId: "app", args: ["size": 4]))
        #expect(call.surfaceId == "s")
        var received: A2UIFunctionResponse?
        store.onAgentFunctionResponse = { received = $0 }
        store.apply(.agentFunctionResponse(A2UIFunctionResponse(functionCallId: call.functionCallId, result: .success(true))))
        #expect(received?.functionCallId == call.functionCallId)
    }

    @Test func agentCallsRespectAllowedCallers() {
        let store = A2UISurfaceStore(functions: .basic.registering(A2UIFunctionDefinition(
            "cartTotal", returns: "number", callers: .rendererOrAgent,
            body: .pure { args in .number((args["items"]?.arrayValue ?? []).compactMap(\.doubleValue).reduce(0, +)) })))
        var sent: [A2UIRendererMessage] = []
        store.onMessageToAgent = { sent.append($0) }
        store.apply(.create("s"))
        store.apply(.updateDataModel(surfaceId: "s", path: "/items", value: [2, 3.5]))
        store.apply(.callRendererFunction(functionCallId: "1", surfaceId: "s",
                                          call: A2UIFunctionCall(name: "cartTotal", catalogId: "c", args: ["items": ["@path": "/items"]])))
        store.apply(.callRendererFunction(functionCallId: "2", surfaceId: nil,
                                          call: A2UIFunctionCall(name: "formatNumber", catalogId: "c", args: ["value": 1])))
        store.apply(.callRendererFunction(functionCallId: "3", surfaceId: "gone",
                                          call: A2UIFunctionCall(name: "cartTotal", catalogId: "c")))
        store.apply(.callRendererFunction(functionCallId: "4", surfaceId: nil,
                                          call: A2UIFunctionCall(name: "nope", catalogId: "c")))
        let results = sent.compactMap { message -> (String, String?)? in
            guard case .rendererFunctionResponse(let r) = message else { return nil }
            switch r.result {
            case .success(let v): return (r.functionCallId, v.displayString)
            case .failure(let e): return (r.functionCallId, e.code)
            }
        }
        #expect(results.map(\.0) == ["1", "2", "3", "4"])
        #expect(results.map(\.1) == ["5.5", "INVALID_FUNCTION_CALL", "INVALID_FUNCTION_CALL", "INVALID_FUNCTION_CALL"])
    }

    @Test func duplicateCreateSendsAnIntegrityError() {
        let store = A2UISurfaceStore()
        var sent: [A2UIRendererMessage] = []
        store.onMessageToAgent = { sent.append($0) }
        store.apply(.create("s"))
        store.apply(.create("s"))
        #expect(sent == [.error(A2UIRendererError(code: "INTEGRITY_ERROR", message: "Surface 's' already exists", surfaceId: "s"))])
    }

    @Test func compositionRulesMarkDisallowedNesting() throws {
        let store = surfaceStore([
            A2UIComponent(id: "root", type: "Column", properties: ["children": ["pay", "summary"]]),
            A2UIComponent(id: "pay", type: "PayButton"),
            A2UIComponent(id: "summary", type: "OrderSummary", properties: ["child": "pay2"]),
            A2UIComponent(id: "pay2", type: "PayButton"),
        ])
        let rules = A2UISurface.CompositionRules(allowedParents: ["PayButton": ["OrderSummary"]])
        let tree = try #require(store.surfaces["s"]?.resolvedTree(rules: rules))
        #expect(shape(tree) == "root(pay!,summary(pay2))")
        guard case .invalid(let reason) = tree.children[0].state else { Issue.record("expected invalid"); return }
        #expect(reason.hasPrefix("UNALLOWED_PARENT"))
    }

    @Test func templatesExposeTheirIndex() throws {
        let store = surfaceStore([
            A2UIComponent(id: "root", type: "List", properties: ["children": ["componentId": "row", "path": "/items"]]),
            A2UIComponent(id: "row", type: "Text", properties: ["text": ["@call": "formatString", "args": ["value": "${@index(offset: 1)}. ${name}"]]]),
        ], data: ["items": [["name": "Tea"], ["name": "Cake"]]])
        let surface = try #require(store.surfaces["s"])
        let tree = try #require(surface.resolvedTree())
        let texts = tree.children.map { surface.string("text", of: $0.component!, scope: $0.scope, index: $0.index) }
        #expect(texts == ["1. Tea", "2. Cake"])
    }
}

@Suite("A2UI 1.0 catalogs")
@MainActor
struct Catalog10Tests {
    @Test func catalogDefinitionFollowsThe10Schema() throws {
        let manifest = A2UICatalog.fluid.manifest(version: "7")
        let definition = manifest.catalogDefinition(functions: .basic)
        #expect(definition["protocolVersion"] == "1.0")
        #expect(definition["$id"] == definition["catalogId"])
        #expect(definition["components"]?["Table"]?["properties"]?["component"] == ["const": "Table"])
        #expect(definition["components"]?["Button"]?["properties"]?["action"]?["$ref"] == "common_types.json#/$defs/Action")
        #expect(definition["functions"]?["openUrl"]?["requiresUserActivation"] == true)
        #expect(definition["functions"]?["openUrl"]?["returnType"] == "void")
        let caps = A2UICatalogManifest.rendererCapabilities(supporting: [manifest, A2UICatalog.basic.manifest(version: "1")])
        #expect(caps["1.0"]?["supportedCatalogIds"] == [.string(manifest.catalogId), .string(A2UIVersion.basicCatalogID)])
    }

    @Test func eachComponentIsDrawnByTheCatalogItNames() throws {
        let app = A2UICatalog(id: "app", including: .basic)
        let store = A2UISurfaceStore()
        store.apply(.create("s", catalog: "app"))
        let env = A2UIRenderEnvironment(store: store, surfaceId: "s", catalogs: [app, .fluid], baseURL: nil, onAction: { _ in })
        let surface = try #require(store.surfaces["s"])
        #expect(env.catalog(for: A2UIComponent(id: "a", type: "Text"), in: surface)?.id == "app")
        #expect(env.catalog(for: A2UIComponent(id: "b", type: "Table", properties: ["@catalogId": .string(A2UICatalog.fluid.id)]), in: surface)?.id
                == A2UICatalog.fluid.id)
        #expect(env.catalog(for: A2UIComponent(id: "c", type: "Text", properties: ["@catalogId": "unknown"]), in: surface) == nil)
        // No surface default and no @catalogId: nothing draws it (1.0 has no other fallback).
        store.apply(.create("bare", catalog: nil))
        #expect(env.catalog(for: A2UIComponent(id: "d", type: "Text"), in: try #require(store.surfaces["bare"])) == nil)
    }

    @Test func markdownHeadingsBecomeHeadingBlocks() {
        let blocks = A2UIMarkdown.blocks("## Trip to Lisbon\nTwo **nights**\n#nospace")
        #expect(blocks.map(\.level) == [2, 0])
        #expect(String(blocks[0].text.characters) == "Trip to Lisbon")
        #expect(String(blocks[1].text.characters) == "Two nights\n#nospace")
    }

    @Test func mediaURLsFollowThe10Rules() {
        #expect(A2UIURLPolicy.allowedURL("https:host/x.png") == nil)
        #expect(A2UIURLPolicy.allowedURL("ht\ttps://host/x.png") == nil)
        #expect(A2UIURLPolicy.allowedURL("/\\host/x.png", relativeTo: URL(string: "https://app.example/")) == nil)
        #expect(A2UIURLPolicy.openableURL("mailto:a@b.c") == nil)
        #expect(A2UIURLPolicy.openableURL("https://a2ui.org")?.host == "a2ui.org")
    }
}
