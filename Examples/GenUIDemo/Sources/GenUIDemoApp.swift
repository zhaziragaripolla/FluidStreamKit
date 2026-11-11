import SwiftUI
import FluidStreamUI
import FluidStreamHostUI

@main
struct GenUIDemoApp: App {
    var body: some Scene {
        WindowGroup { DemoView() }
    }
}

// MARK: - The app's own component

/// Decoded from the component's properties, with data-model bindings already resolved.
struct Stay: Decodable {
    let name: String
    let price: String
    let rating: Double
    let perks: [String]
}

struct StayCard: View {
    let stay: Stay?

    var body: some View {
        if let stay {
            VStack(alignment: .leading, spacing: 0) {
                LinearGradient(colors: [.orange, .pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 110)
                    .overlay(alignment: .bottomLeading) {
                        Label(String(format: "%.1f", stay.rating), systemImage: "star.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(stay.name).font(.headline)
                        Spacer()
                        Text(stay.price).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        ForEach(stay.perks, id: \.self) { perk in
                            Text(perk).font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .padding(12)
            }
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(stay.name), \(stay.price), rated \(String(format: "%.1f", stay.rating))")
        } else {
            // The component arrived before its data.
            RoundedRectangle(cornerRadius: 16).fill(.quaternary).frame(height: 180).accessibilityHidden(true)
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class DemoModel {
    private(set) var store = A2UISurfaceStore()
    private(set) var session = StreamSession()
    private(set) var lastSent: String?
    private var task: Task<Void, Never>?

    /// The app's own catalog: the basic components plus StayCard, under the app's own id.
    let catalog = A2UICatalog(id: "dev.fluidstreamkit.genuidemo:catalog/1", including: .basic)
        .registering("StayCard") { context in
            StayCard(stay: context.props(as: Stay.self))
        }

    func play() {
        task?.cancel()
        session.cancel()
        store = A2UISurfaceStore()
        session = StreamSession()
        lastSent = nil
        let session = session, store = store
        task = Task {
            // 1. Text, through the v1 engine.
            await session.start { buffer in
                for word in AgentScript.intro.split(separator: " ") {
                    try await buffer.append(word + " ")
                    try await Task.sleep(for: .milliseconds(35))
                }
            }
            // 2. The surface, as JSONL arriving a few bytes at a time.
            var decoder = A2UILineDecoder()
            for line in AgentScript.surface {
                let bytes = Array((line + "\n").utf8)
                var start = 0
                while start < bytes.count {
                    let end = min(start + 96, bytes.count)
                    store.apply(decoder.feed(bytes[start..<end]))
                    start = end
                    try? await Task.sleep(for: .milliseconds(12))
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(for: .milliseconds(260))
            }
        }
    }

    func handle(_ action: A2UIAction) {
        // A real app sends every message to its agent. Here we show it, and script the reply.
        if let message = action.messageToAgent {
            lastSent = (try? message.encoded()).map { String(decoding: $0, as: UTF8.self) }
        }
        switch action {
        case .event(let event):
            guard event.name == "book" else { return }
            let store = store
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                for value in AgentScript.bookingReply(to: event) {
                    if let message = try? A2UIMessage.decode(value) { store.apply(message) }
                }
            }
        case .localFunction(let name, _):
            lastSent = "Declined on-device function: \(name)"
        case .callAgentFunction, .error:
            break
        }
    }
}

// MARK: - Screen

struct DemoView: View {
    @State private var model = DemoModel()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(AgentScript.prompt)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        FluidStreamView(renderer: model.session.renderer)
                            .id(ObjectIdentifier(model.session))
                            .frame(height: 96)

                        A2UISurfaceView(store: model.store, surfaceId: "trip", catalog: model.catalog) { action in
                            model.handle(action)
                        }
                        .animation(.snappy(duration: 0.25), value: model.store.surfaces["trip"])

                        if let sent = model.lastSent {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sent to agent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(sent).font(.caption2.monospaced())
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                            .id("sent")
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.lastSent) {
                    withAnimation { proxy.scrollTo("sent", anchor: .bottom) }
                }
            }
            .navigationTitle("GenUI Demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Replay", systemImage: "arrow.clockwise") { model.play() }
            }
            .task { model.play() }
        }
    }
}
