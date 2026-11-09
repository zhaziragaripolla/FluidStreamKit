/// Decides whether the view should keep following the streaming tail.
///
/// A pure state machine with no UIKit, so every transition can be tested on the host
/// machine. `StreamTextView` turns scroll-view callbacks into these calls.
///
/// | Input | Effect |
/// |---|---|
/// | drag begins | stop moving the content (never fight the finger) |
/// | drag translation > `detachTranslation` toward earlier content | detach **immediately** |
/// | drag ends with projected landing ≤ `reattachDistance` from the bottom | re-attach once settled |
/// | scroll settles ≤ `reattachDistance` from the bottom | re-attach |
/// | scroll to top (status-bar tap) | detach |
/// | jump to latest | re-attach |
public struct AutoScrollPolicy: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case following
        case detached
    }

    public private(set) var mode = Mode.following
    public private(set) var isDragging = false
    public private(set) var isDecelerating = false

    /// The points of downward finger travel (toward earlier content) that count as
    /// "I want to read back".
    public var detachTranslation: Double
    /// How close to the bottom counts as "at the latest content".
    public var reattachDistance: Double

    public init(detachTranslation: Double = 2, reattachDistance: Double = 32) {
        self.detachTranslation = detachTranslation
        self.reattachDistance = reattachDistance
    }

    /// True when the view should move the content to keep the tail visible this frame.
    public var shouldFollowTail: Bool {
        mode == .following && !isDragging && !isDecelerating
    }

    public mutating func dragBegan() {
        isDragging = true
        isDecelerating = false
    }

    /// `translationY` is the drag's cumulative pan translation. Positive means the finger
    /// moved down, revealing earlier content.
    public mutating func dragChanged(translationY: Double) {
        if translationY > detachTranslation { mode = .detached }
    }

    /// `projectedDistanceFromBottom` is the distance between where the scroll will come to
    /// rest (UIKit's `targetContentOffset`) and the bottom. Using the projection makes the
    /// policy velocity-aware: a fling toward the bottom re-attaches without waiting for it
    /// to land.
    public mutating func dragEnded(projectedDistanceFromBottom: Double, willDecelerate: Bool) {
        isDragging = false
        isDecelerating = willDecelerate
        if projectedDistanceFromBottom <= reattachDistance { mode = .following }
    }

    public mutating func scrollSettled(distanceFromBottom: Double) {
        isDragging = false
        isDecelerating = false
        if distanceFromBottom <= reattachDistance { mode = .following }
    }

    public mutating func scrolledToTop() {
        isDecelerating = false
        mode = .detached
    }

    public mutating func jumpToLatest() {
        isDragging = false
        isDecelerating = false
        mode = .following
    }
}
