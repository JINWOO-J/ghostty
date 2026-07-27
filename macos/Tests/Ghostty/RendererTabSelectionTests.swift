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
}
