import SwiftUI
import FluidStreamUI
import AnthropicStreaming

@main
struct AnthropicChatApp: App {
    var body: some Scene {
        WindowGroup { ChatView() }
    }
}

/// One question, one streamed answer. Each Send starts a fresh `StreamSession`.
@MainActor
@Observable
final class ChatModel {
    /// Kept in memory only, never saved. Don't ship an API key inside an app: in production,
    /// call your own backend, which holds the key and relays the stream.
    var apiKey = ""
    var prompt = "How does SwiftUI's task(id:) modifier cancel work? Include a short code example."
    private(set) var session: StreamSession?
    private(set) var notice: String?

    func send() {
        session?.cancel()
        let session = StreamSession(parserConfiguration: MessagesTextBridge.parserConfiguration)
        self.session = session
        notice = nil

        let streamer = MessagesStreamer(apiKey: apiKey)
        let request = MessagesRequest(prompt: prompt)
        Task {
            await session.start { buffer in
                do {
                    let outcome = try await streamer.stream(request, into: buffer)
                    await self.show(outcome.notice)
                } catch {
                    await self.show(Self.describe(error))
                    throw error                      // cancels the session; text so far stays
                }
            }
        }
    }

    private func show(_ text: String?) {
        notice = text
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        switch error {
        case MessagesStreamError.http(let status, let body): "HTTP \(status): \(body.prefix(200))"
        case MessagesStreamError.api(let type, let message): "\(type): \(message)"
        default: error.localizedDescription
        }
    }
}

struct ChatView: View {
    @State private var model = ChatModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let session = model.session {
                    FluidStreamView(renderer: session.renderer)
                        .id(ObjectIdentifier(session))
                } else {
                    ContentUnavailableView(
                        "Ask Claude",
                        systemImage: "text.bubble",
                        description: Text("The answer streams in through FluidStreamKit.")
                    )
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                }
                Divider()
                VStack(spacing: 8) {
                    SecureField("Anthropic API key (kept in memory only)", text: $model.apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    HStack(alignment: .bottom) {
                        TextField("Message", text: $model.prompt, axis: .vertical)
                            .lineLimit(1...4)
                        Button("Send", action: model.send)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.apiKey.isEmpty || model.prompt.isEmpty)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding()
            }
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
