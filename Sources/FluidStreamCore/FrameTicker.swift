#if canImport(UIKit)
public import UIKit
#endif

/// One display refresh.
public struct FrameTick: Sendable, Equatable {
    /// When the previous frame was displayed (`CADisplayLink.timestamp`).
    public let timestamp: Double
    /// When the frame being prepared will be displayed (`CADisplayLink.targetTimestamp`).
    /// `targetTimestamp - now` is the remaining budget.
    public let targetTimestamp: Double

    public init(timestamp: Double, targetTimestamp: Double) {
        self.timestamp = timestamp
        self.targetTimestamp = targetTimestamp
    }
}

/// A source of vsync callbacks. It's abstracted so the coordinator can be tested
/// deterministically, without a display.
@MainActor
public protocol FrameTicker: AnyObject {
    var isPaused: Bool { get set }
    func start(_ handler: @escaping @MainActor (FrameTick) -> Void)
    func invalidate()
}

/// A deterministic ticker for unit tests and headless benchmarks. Call `fire()` to emit one frame.
@MainActor
public final class ManualFrameTicker: FrameTicker {
    public var isPaused = false
    public private(set) var isInvalidated = false
    public let frameInterval: Double
    private var handler: (@MainActor (FrameTick) -> Void)?
    private var now: Double = 0

    public init(frameInterval: Double = 1.0 / 120.0) {
        self.frameInterval = frameInterval
    }

    public func start(_ handler: @escaping @MainActor (FrameTick) -> Void) {
        guard !isInvalidated else { return }
        self.handler = handler
    }

    /// Emits a tick unless paused or invalidated. Returns whether a tick was delivered.
    @discardableResult
    public func fire() -> Bool {
        guard !isPaused, !isInvalidated, let handler else { return false }
        let tick = FrameTick(timestamp: now, targetTimestamp: now + frameInterval)
        now += frameInterval
        handler(tick)
        return true
    }

    public func invalidate() {
        isInvalidated = true
        handler = nil
    }
}

#if canImport(UIKit)
/// The production ticker, backed by `CADisplayLink`.
///
/// - Added to the `.common` run-loop mode. In `.default` mode the link stops firing while
///   the user is touching a scroll view (which switches the run loop to `.tracking`), so
///   streaming would freeze exactly when the user is reading.
/// - The display link retains its target, so it targets a weak proxy. That breaks the
///   `CADisplayLink → target` retain cycle, and the proxy invalidates the link if its owner
///   has been deallocated.
/// - On iPhone, 120 Hz requires `CADisableMinimumFrameDurationOnPhone = YES` in the host
///   app's Info.plist. Without it the system caps the link at 60 Hz. That's still correct,
///   just at a lower rate.
@MainActor
public final class DisplayLinkTicker: FrameTicker {
    private var link: CADisplayLink?
    private var handler: (@MainActor (FrameTick) -> Void)?
    private let frameRateRange: CAFrameRateRange

    public init(frameRateRange: CAFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)) {
        self.frameRateRange = frameRateRange
    }

    public var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    public func start(_ handler: @escaping @MainActor (FrameTick) -> Void) {
        guard link == nil else { return }
        self.handler = handler
        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = frameRateRange
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    public func invalidate() {
        link?.invalidate()
        link = nil
        handler = nil
    }

    fileprivate func fire(_ link: CADisplayLink) {
        handler?(FrameTick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp))
    }
}

@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var owner: DisplayLinkTicker?

    init(owner: DisplayLinkTicker) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.fire(link)
    }
}
#endif
