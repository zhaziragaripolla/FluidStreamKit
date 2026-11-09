#if canImport(UIKit)
internal import UIKit
#else
internal import Foundation
#endif

/// Drains a `StreamBufferActor` at most once per display frame and hands each batch to the
/// renderer on the main actor.
///
/// ```
/// ticker ─tick─▶ AsyncStream(.bufferingNewest(1)) ─▶ consumer loop ─await drain─▶ onFlush
/// ```
///
/// - **Coalescing:** if the main actor falls behind, unhandled ticks collapse to the newest
///   one. A single displayed frame never triggers two drains.
/// - **Idle pause:** after `policy.idleFramesBeforePause` empty frames the ticker is paused.
///   The buffer's data-available hook wakes it again.
/// - **Lifecycle:** on UIKit platforms the ticker pauses automatically in the background and
///   resumes in the foreground. `enterBackground()` / `enterForeground()` are public for
///   hosts with custom lifecycles, and for tests.
/// - **Teardown:** call `stop()` (it's idempotent). It also runs automatically after the
///   final batch has been delivered.
@MainActor
public final class DisplayLinkCoordinator {
    public enum Phase: Sendable, Equatable {
        case idle, running, idlePaused, backgrounded, stopped
    }

    public typealias FlushHandler = @MainActor (FrameBatch) -> Void

    public private(set) var phase = Phase.idle
    /// The number of ticks handled, including empty ones. Used for instrumentation and tests.
    public private(set) var framesHandled = 0

    private let buffer: StreamBufferActor
    private let ticker: any FrameTicker
    private let policy: FlushPolicy
    private let onFlush: FlushHandler

    private var tickContinuation: AsyncStream<FrameTick>.Continuation?
    private var consumer: Task<Void, Never>?
    private var idleFrames = 0
    /// Tracked separately from `phase`, so a background notification that arrives before
    /// `start()`, or while the coordinator is idle, isn't lost.
    private var isInBackground = false
    private var lifecycleObservers: [any NSObjectProtocol] = []

    public init(
        buffer: StreamBufferActor,
        ticker: any FrameTicker,
        policy: FlushPolicy = FlushPolicy(),
        onFlush: @escaping FlushHandler
    ) {
        self.buffer = buffer
        self.ticker = ticker
        self.policy = policy
        self.onFlush = onFlush
    }

    #if canImport(UIKit)
    public convenience init(
        buffer: StreamBufferActor,
        policy: FlushPolicy = FlushPolicy(),
        onFlush: @escaping FlushHandler
    ) {
        self.init(buffer: buffer, ticker: DisplayLinkTicker(), policy: policy, onFlush: onFlush)
    }
    #endif

    /// Starts frame-synced draining. Calling it again has no effect.
    public func start() async {
        guard phase == .idle else { return }
        phase = .running

        let (ticks, continuation) = AsyncStream.makeStream(of: FrameTick.self, bufferingPolicy: .bufferingNewest(1))
        tickContinuation = continuation

        await buffer.setDataAvailableHandler { [weak self] in
            Task { @MainActor in self?.wake() }
        }
        guard phase == .running else { return }   // stop() could have run during the await

        ticker.start { tick in continuation.yield(tick) }
        installLifecycleObservers()
        #if canImport(UIKit)
        // A stream can start while the app is already in the background (for example a
        // request made just before the user switched apps). No notification will arrive, so check.
        if UIApplication.shared.applicationState == .background { isInBackground = true }
        #endif
        if isInBackground {
            phase = .backgrounded
            ticker.isPaused = true
        }

        consumer = Task { [weak self] in
            for await tick in ticks {
                guard let self else { return }
                await self.handle(tick)
            }
        }
    }

    /// Tears everything down. Batches not yet drained are discarded.
    public func stop() {
        guard phase != .stopped else { return }
        phase = .stopped
        ticker.invalidate()
        tickContinuation?.finish()
        tickContinuation = nil
        consumer?.cancel()
        consumer = nil
        removeLifecycleObservers()
        let buffer = buffer
        Task { await buffer.setDataAvailableHandler(nil) }
    }

    public func enterBackground() {
        isInBackground = true
        guard phase == .running || phase == .idlePaused else { return }
        phase = .backgrounded
        ticker.isPaused = true
    }

    public func enterForeground() {
        isInBackground = false
        guard phase == .backgrounded else { return }
        resumeTicking()
    }

    // MARK: Private

    private func wake() {
        switch phase {
        case .idlePaused: resumeTicking()
        case .running: idleFrames = 0     // data arrived while counting down to the idle pause
        case .idle, .backgrounded, .stopped: break
        }
    }

    private func resumeTicking() {
        phase = .running
        idleFrames = 0
        ticker.isPaused = false
    }

    private func handle(_ tick: FrameTick) async {
        guard phase == .running else { return }
        let batch = await buffer.drain(policy: policy)
        // This is a suspension point, so `phase` may have changed meanwhile. The batch has
        // already been removed from the buffer, so deliver it unless we were stopped.
        guard phase != .stopped else { return }
        framesHandled += 1

        guard let batch else {
            idleFrames += 1
            if phase == .running, idleFrames >= policy.idleFramesBeforePause {
                phase = .idlePaused
                ticker.isPaused = true
            }
            return
        }

        idleFrames = 0
        onFlush(batch)
        if batch.isFinal { stop() }
    }

    private func installLifecycleObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterForeground() }
            },
        ]
        #endif
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }
}
