import Testing
@testable import Ghostty

struct RendererTabSelectionTests {
    @Test func standaloneWindowIsSelected() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: false,
            selectedWindowMatches: nil,
            isKeyOrMain: false
        ) == .selected)
    }

    @Test func matchingGroupSelectionIsSelected() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: true,
            isKeyOrMain: false
        ) == .selected)
    }

    @Test func differentGroupSelectionIsDeselected() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: false,
            isKeyOrMain: false
        ) == .deselected)
    }

    @Test func missingGroupSelectionIsAmbiguous() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: nil,
            isKeyOrMain: false
        ) == .ambiguous)
    }

    @Test func keyWindowOverridesTransientGroupSelection() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: false,
            isKeyOrMain: true
        ) == .selected)
    }

    @Test func keyWindowRemainsVisibleWhileOcclusionStateLagsTabSelection() {
        #expect(RendererTabVisibility.isVisible(
            selection: .selected,
            occlusionVisible: false,
            isKeyOrMain: true
        ))
    }

    @Test func tabOverviewClassifiesEveryMemberAsOverview() {
        #expect(RendererTabSelection.classify(
            hasTabGroup: true,
            selectedWindowMatches: false,
            isKeyOrMain: false,
            isOverviewVisible: true
        ) == .overview)
    }

    @Test func tabOverviewKeepsRendererVisibleAndNonReclaimable() {
        #expect(RendererTabVisibility.isVisible(
            selection: .overview,
            occlusionVisible: false,
            isKeyOrMain: false
        ))
        #expect(!RendererTabVisibility.shouldReclaimSynchronously(
            selection: .overview
        ))
    }

    @Test func deselectedTabReclaimsRendererInCurrentVisibilityPass() {
        #expect(RendererTabVisibility.shouldReclaimSynchronously(
            selection: .deselected
        ))
        #expect(!RendererTabVisibility.shouldReclaimSynchronously(
            selection: .selected
        ))
        #expect(!RendererTabVisibility.shouldReclaimSynchronously(
            selection: .ambiguous
        ))
    }

    @Test func missingSurfaceDoesNotRetryRendererReclamation() {
        var releaseAttempts = 0

        let needsRetry = RendererReclamationRetry.shouldRetry(
            hasSurface: false,
            releaseAccepted: {
                releaseAttempts += 1
                return false
            }()
        )

        #expect(!needsRetry)
        #expect(releaseAttempts == 0)
    }

    @Test func tabGroupElectsOneRendererObservationOwner() {
        let observers = (0..<100).filter {
            RendererTabObservationPlan.shouldObserve(controllerIndex: $0)
        }

        #expect(observers == [0])
    }
}
