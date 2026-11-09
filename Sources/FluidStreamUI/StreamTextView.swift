#if canImport(UIKit)
public import UIKit
public import SwiftUI

/// A read-only TextKit 2 `UITextView` that shows a `StreamRenderer`'s document and follows
/// the streaming tail.
///
/// - The text view is built on the document's own TextKit 2 stack (`textContainer`
///   → `NSTextLayoutManager` → `NSTextContentStorage`), so edits go straight to it.
/// - Following the tail sets `contentOffset` directly, once per frame, with no animation.
///   An animated scroll at 120 Hz queues overlapping animations and stutters.
/// - Scroll-view callbacks feed `AutoScrollPolicy`. Content offsets the view sets itself
///   aren't drags, so they can never detach the follow.
@MainActor
public final class StreamTextView: UIView, UITextViewDelegate {
    public let textView: UITextView
    public let renderer: StreamRenderer
    public private(set) var scrollPolicy = AutoScrollPolicy()

    /// Called when following starts or stops, e.g. to show a "Jump to latest" button.
    public var onFollowingChanged: ((_ isFollowing: Bool) -> Void)?
    /// Called with `true` when the content starts moving under the user's finger, and with
    /// `false` when that scroll comes to rest (including any deceleration). The view's own
    /// follow-the-tail scrolling never triggers it.
    public var onScrollActivityChanged: ((_ isScrolling: Bool) -> Void)?
    private var isUserScrolling = false

    /// VoiceOver hears finished sentences as they stream (see `StreamAnnouncer`). On by default.
    public var announcesStreamingText = true
    private var announcer = StreamAnnouncer()
    private var announcedLocation = 0

    /// Re-scales the text when the user changes the system text size. On by default.
    public var followsDynamicType = true
    private var observedBodySize = UIFont.preferredFont(forTextStyle: .body).pointSize

    public init(renderer: StreamRenderer) {
        self.renderer = renderer
        textView = UITextView(frame: .zero, textContainer: renderer.document.textContainer)
        super.init(frame: .zero)

        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // If this fires, something accessed `textView.layoutManager` and forced TextKit 1.
        assert(textView.textLayoutManager === renderer.document.textLayoutManager, "TextKit 2 stack not adopted")

        renderer.onContentChange = { [weak self] in self?.contentDidChange() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: StreamTextView, _: UITraitCollection) in
            view.contentSizeCategoryDidChange()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var isFollowing: Bool { scrollPolicy.mode == .following }

    public func jumpToLatest(animated: Bool = true) {
        updatePolicy { $0.jumpToLatest() }
        scrollToBottom(animated: animated)
    }

    // MARK: Following

    private func contentDidChange() {
        announceFinalizedText()
        guard scrollPolicy.shouldFollowTail else { return }
        scrollToBottom(animated: false)
    }

    // MARK: Accessibility

    private func announceFinalizedText() {
        let document = renderer.document
        defer { announcedLocation = document.frozenLength }
        // Skip the work entirely without VoiceOver. Text finalized while it was off is not
        // read out later.
        guard announcesStreamingText, UIAccessibility.isVoiceOverRunning else { return }
        for segment in document.finalizedSegments(from: announcedLocation) {
            announcer.ingest(segment.text, block: segment.block)
        }
        let isFinal = renderer.completion != nil
        guard let text = announcer.announcement(at: CACurrentMediaTime(), isFinal: isFinal) else { return }
        // Queued, so a new sentence never cuts off the one being spoken.
        let speech = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: speech)
    }

    private func contentSizeCategoryDidChange() {
        guard followsDynamicType else { return }
        let newSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        guard newSize != observedBodySize else { return }
        let ratio = newSize / observedBodySize
        observedBodySize = newSize
        renderer.document.applyTheme(renderer.document.theme.scaled(by: ratio))
        if scrollPolicy.shouldFollowTail { scrollToBottom(animated: false) }
    }

    private var maxOffsetY: CGFloat {
        // Only the viewport (now at the tail) is laid out, so contentSize is exact at the bottom.
        max(-textView.adjustedContentInset.top,
            textView.contentSize.height + textView.adjustedContentInset.bottom - textView.bounds.height)
    }

    private func scrollToBottom(animated: Bool) {
        textView.layoutIfNeeded()
        let target = CGPoint(x: textView.contentOffset.x, y: maxOffsetY)
        guard abs(textView.contentOffset.y - target.y) > 0.5 else { return }
        textView.setContentOffset(target, animated: animated)
    }

    private func distanceFromBottom(offsetY: CGFloat) -> Double {
        Double(max(0, maxOffsetY - offsetY))
    }

    private func setUserScrolling(_ scrolling: Bool) {
        guard scrolling != isUserScrolling else { return }
        isUserScrolling = scrolling
        onScrollActivityChanged?(scrolling)
    }

    private func updatePolicy(_ change: (inout AutoScrollPolicy) -> Void) {
        let wasFollowing = isFollowing
        change(&scrollPolicy)
        if wasFollowing != isFollowing { onFollowingChanged?(isFollowing) }
    }

    // MARK: UIScrollViewDelegate

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        updatePolicy { $0.dragBegan() }
        setUserScrolling(true)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging else { return }
        let translation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        updatePolicy { $0.dragChanged(translationY: Double(translation)) }
    }

    public func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let projected = distanceFromBottom(offsetY: targetContentOffset.pointee.y)
        updatePolicy { $0.dragEnded(projectedDistanceFromBottom: projected, willDecelerate: velocity.y != 0) }
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle(scrollView) }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle(scrollView)
    }

    public func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        updatePolicy { $0.scrolledToTop() }
    }

    private func settle(_ scrollView: UIScrollView) {
        let distance = distanceFromBottom(offsetY: scrollView.contentOffset.y)
        updatePolicy { $0.scrollSettled(distanceFromBottom: distance) }
        setUserScrolling(false)
        // New text may have arrived while the user's finger was down. Catch up now.
        if scrollPolicy.shouldFollowTail { scrollToBottom(animated: false) }
    }
}

/// SwiftUI wrapper around `StreamTextView`.
///
/// `updateUIView` is deliberately empty. Streamed text never goes through SwiftUI state, so
/// SwiftUI never invalidates or diffs anything per token. The renderer writes straight into
/// TextKit.
public struct FluidStreamView: UIViewRepresentable {
    private let renderer: StreamRenderer
    private let onFollowingChanged: ((Bool) -> Void)?
    private let onScrollActivityChanged: ((Bool) -> Void)?

    public init(
        renderer: StreamRenderer,
        onFollowingChanged: ((Bool) -> Void)? = nil,
        onScrollActivityChanged: ((Bool) -> Void)? = nil
    ) {
        self.renderer = renderer
        self.onFollowingChanged = onFollowingChanged
        self.onScrollActivityChanged = onScrollActivityChanged
    }

    public func makeUIView(context: Context) -> StreamTextView {
        let view = StreamTextView(renderer: renderer)
        view.onFollowingChanged = onFollowingChanged
        view.onScrollActivityChanged = onScrollActivityChanged
        return view
    }

    public func updateUIView(_ uiView: StreamTextView, context: Context) {}
}
#endif
