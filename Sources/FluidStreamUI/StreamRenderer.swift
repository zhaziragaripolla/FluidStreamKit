public import FluidStreamCore
public import FluidStreamParser
import os

/// Instruments integration. Every rendered frame shows up as a `Frame` interval, labelled
/// with its byte count, on the Points of Interest track. That lets you put each hitch next
/// to the work that caused it. When Instruments isn't recording, the cost is a branch.
enum Instrumentation {
    static let signposter = OSSignposter(subsystem: "FluidStreamKit", category: .pointsOfInterest)
}

/// Connects the pieces: frame batches go into the parser, and the parser's events go into
/// the document.
///
/// Each call to `apply` is one frame. It runs exactly one TextKit editing transaction and
/// then notifies the view once.
@MainActor
public final class StreamRenderer {
    public let document: StreamDocument
    public private(set) var completion: FrameBatch.Completion?

    /// Called after each frame's edits are committed. `StreamTextView` uses it to follow the tail.
    public var onContentChange: (() -> Void)?
    /// Called when a tool call's JSON is complete, or when it was cut off.
    public var onToolCall: ((_ json: String, _ isStructurallyComplete: Bool) -> Void)?

    private var parser: StreamParser

    public init(theme: StreamTheme = .standard(), parserConfiguration: ParserConfiguration = ParserConfiguration()) {
        document = StreamDocument(theme: theme)
        parser = StreamParser(configuration: parserConfiguration)
    }

    public func apply(_ batch: FrameBatch) {
        apply(text: batch.text, isFinal: batch.isFinal)
        if let completion = batch.completion { self.completion = completion }
    }

    /// Applies one frame of text directly, without a `StreamBufferActor`. Useful for replaying
    /// a stored response.
    public func apply(text: String, isFinal: Bool = false) {
        guard completion == nil else { return }
        let signpost = Instrumentation.signposter.beginInterval("Frame", "\(text.utf8.count) bytes")
        defer { Instrumentation.signposter.endInterval("Frame", signpost) }
        var toolCalls: [(String, Bool)] = []
        document.performFrame { document in
            let sink: (ParseEvent) -> Void = { event in
                if case .toolCallPayload(let json, let complete) = event { toolCalls.append((json, complete)) }
                document.apply(event)
            }
            if !text.isEmpty { parser.feed(text, emit: sink) }
            if isFinal {
                parser.finish(emit: sink)
                document.finish()
            }
        }
        if isFinal && completion == nil { completion = .finished }
        for (json, complete) in toolCalls { onToolCall?(json, complete) }
        onContentChange?()
    }
}

/// The whole pipeline for one response:
///
/// ```
/// producer ─▶ StreamBufferActor ─▶ DisplayLinkCoordinator ─▶ StreamRenderer ─▶ StreamDocument
/// ```
@MainActor
public final class StreamSession {
    public let renderer: StreamRenderer
    public let buffer: StreamBufferActor
    public let coordinator: DisplayLinkCoordinator
    /// Set synchronously on the first `start()`, before its first suspension point, so a
    /// second concurrent `start()` (a double tap on Send, a retry racing the first request)
    /// is ignored instead of attaching a second producer to the buffer.
    private var hasStarted = false
    /// Lock-protected so `deinit`, which isn't isolated to the main actor, can cancel it.
    private let producer = ProducerHandle()

    public init(
        ticker: any FrameTicker,
        flushPolicy: FlushPolicy = FlushPolicy(),
        bufferCapacity: Int = 64 * 1024,
        theme: StreamTheme = .standard(),
        parserConfiguration: ParserConfiguration = ParserConfiguration()
    ) {
        let renderer = StreamRenderer(theme: theme, parserConfiguration: parserConfiguration)
        let buffer = StreamBufferActor(capacity: bufferCapacity)
        self.renderer = renderer
        self.buffer = buffer
        coordinator = DisplayLinkCoordinator(buffer: buffer, ticker: ticker, policy: flushPolicy) { [weak renderer] batch in
            renderer?.apply(batch)
        }
    }

    #if canImport(UIKit)
    public convenience init(
        flushPolicy: FlushPolicy = FlushPolicy(),
        bufferCapacity: Int = 64 * 1024,
        theme: StreamTheme = .standard(),
        parserConfiguration: ParserConfiguration = ParserConfiguration()
    ) {
        self.init(
            ticker: DisplayLinkTicker(),
            flushPolicy: flushPolicy,
            bufferCapacity: bufferCapacity,
            theme: theme,
            parserConfiguration: parserConfiguration
        )
    }
    #endif

    /// Starts rendering and runs `produce` off the main actor. `produce` writes the response
    /// into the buffer, for example from an SSE decoder.
    ///
    /// If `produce` returns, the stream finishes. If it throws, or the session is cancelled,
    /// the stream is cancelled and the text rendered so far stays on screen.
    ///
    /// Append chunks rather than single bytes: each `append` is an actor hop.
    public func start(_ produce: @escaping @Sendable (StreamBufferActor) async throws -> Void) async {
        guard !hasStarted else { return }
        hasStarted = true
        await coordinator.start()
        let buffer = buffer
        producer.set(Task.detached {
            do {
                try await produce(buffer)
                await buffer.finish()
            } catch {
                await buffer.cancel()
            }
        })
    }

    public func cancel() {
        producer.cancel()
        let buffer = buffer
        Task { await buffer.cancel() }
    }

    /// A session released without `cancel()`, for example when its screen is dismissed
    /// mid-answer, must not leave its producer suspended on backpressure forever, or keep its
    /// display link running. Only `let` properties of `Sendable` types are touched here.
    deinit {
        producer.cancel()
        let buffer = buffer
        let coordinator = coordinator
        Task { await buffer.cancel() }
        Task { @MainActor in coordinator.stop() }
    }
}

/// Holds the producer task behind a lock, so it can be cancelled from `deinit`.
private final class ProducerHandle: Sendable {
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    func set(_ newTask: Task<Void, Never>) {
        task.withLock { $0 = newTask }
    }

    func cancel() {
        task.withLock { $0 }?.cancel()
    }
}
