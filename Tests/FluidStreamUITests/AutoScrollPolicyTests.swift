import Testing
import FluidStreamUI

@Suite("AutoScrollPolicy")
struct AutoScrollPolicyTests {
    @Test func followsByDefault() {
        let policy = AutoScrollPolicy()
        #expect(policy.mode == .following)
        #expect(policy.shouldFollowTail)
    }

    @Test func touchPausesFollowingWithoutDetaching() {
        var policy = AutoScrollPolicy()
        policy.dragBegan()
        #expect(policy.mode == .following)
        #expect(!policy.shouldFollowTail)          // never move content under the finger
    }

    @Test func smallJitterDoesNotDetach() {
        var policy = AutoScrollPolicy()
        policy.dragBegan()
        policy.dragChanged(translationY: 1.5)
        #expect(policy.mode == .following)
    }

    @Test func panTowardEarlierContentDetachesImmediately() {
        var policy = AutoScrollPolicy()
        policy.dragBegan()
        policy.dragChanged(translationY: 2.5)      // first callback past the threshold
        #expect(policy.mode == .detached)
    }

    @Test func panTowardNewerContentKeepsFollowing() {
        var policy = AutoScrollPolicy()
        policy.dragBegan()
        policy.dragChanged(translationY: -40)
        policy.dragEnded(projectedDistanceFromBottom: 0, willDecelerate: false)
        #expect(policy.shouldFollowTail)
    }

    @Test func flingProjectedToBottomReattachesButWaitsForLanding() {
        var policy = AutoScrollPolicy()
        policy.dragBegan()
        policy.dragChanged(translationY: 30)
        policy.dragEnded(projectedDistanceFromBottom: 10, willDecelerate: true)
        #expect(policy.mode == .following)
        #expect(!policy.shouldFollowTail)          // still decelerating
        policy.scrollSettled(distanceFromBottom: 10)
        #expect(policy.shouldFollowTail)
    }

    @Test func flingThatLandsFarAwayStaysDetached() {
        var policy = AutoScrollPolicy()
        policy.dragBegan()
        policy.dragChanged(translationY: 30)
        policy.dragEnded(projectedDistanceFromBottom: 800, willDecelerate: true)
        policy.scrollSettled(distanceFromBottom: 800)
        #expect(policy.mode == .detached)
        #expect(!policy.shouldFollowTail)
    }

    @Test func settlingNearBottomReattaches() {
        var policy = AutoScrollPolicy()
        policy.dragBegan()
        policy.dragChanged(translationY: 30)
        policy.dragEnded(projectedDistanceFromBottom: 200, willDecelerate: false)
        #expect(policy.mode == .detached)
        policy.dragBegan()
        policy.dragEnded(projectedDistanceFromBottom: 31, willDecelerate: false)
        #expect(policy.shouldFollowTail)
    }

    @Test func scrollToTopDetachesAndJumpReattaches() {
        var policy = AutoScrollPolicy()
        policy.scrolledToTop()
        #expect(policy.mode == .detached)
        policy.jumpToLatest()
        #expect(policy.shouldFollowTail)
    }

    @Test func thresholdsAreConfigurable() {
        var policy = AutoScrollPolicy(detachTranslation: 10, reattachDistance: 5)
        policy.dragBegan()
        policy.dragChanged(translationY: 8)
        #expect(policy.mode == .following)
        policy.dragChanged(translationY: 12)
        policy.dragEnded(projectedDistanceFromBottom: 6, willDecelerate: false)
        #expect(policy.mode == .detached)
    }
}
