import Testing
@testable import DictationMac

@Suite("Web and custom editor focus")
struct FocusedInputResolverTests {
    struct Node {
        var owner: Int32
        var parent: Int? = nil
        var focusedChild: Int? = nil
        var isInput = false
        var children: [Int] = []
        var isFocused = false
    }

    func resolve(_ nodes: [Int: Node], system: Int?, app: Int?) -> Int? {
        FocusedInputResolver<Int>(
            same: { $0 == $1 }, owner: { nodes[$0]?.owner },
            parent: { nodes[$0]?.parent }, focusedChild: { nodes[$0]?.focusedChild },
            isInput: { nodes[$0]?.isInput == true },
            children: { nodes[$0]?.children ?? [] }, isFocused: { nodes[$0]?.isFocused == true }
        ).resolve(systemFocus: system, applicationFocus: app, appProcessID: 777)
    }

    @Test func aWebViewFocusChainReachesTheRendererTextArea() {
        let nodes = [
            1: Node(owner: 777),
            2: Node(owner: 888, parent: 1, focusedChild: 3),
            3: Node(owner: 888, parent: 2, isInput: true),
        ]
        #expect(resolve(nodes, system: 2, app: 2) == 3)
    }

    @Test func applicationFocusCanRefineASystemWebContainer() {
        let nodes = [
            1: Node(owner: 777),
            2: Node(owner: 888, parent: 1),
            3: Node(owner: 888, parent: 2, isInput: true),
        ]
        #expect(resolve(nodes, system: 2, app: 3) == 3)
    }

    @Test func focusOnTextInsideTheEditorIdentifiesItsEditableParent() {
        let nodes = [
            1: Node(owner: 777, isInput: true),
            2: Node(owner: 777, parent: 1),
        ]
        #expect(resolve(nodes, system: 2, app: 2) == 1)
    }

    @Test func aRendererInputExposedByTheApplicationIsAccepted() {
        #expect(resolve([1: Node(owner: 888, isInput: true)], system: 1, app: 1) == 1)
    }

    @Test func aForeignPanelCannotUseTheApplicationsStaleFocus() {
        let nodes = [1: Node(owner: 777, isInput: true), 9: Node(owner: 999, isInput: true)]
        #expect(resolve(nodes, system: 9, app: 1) == nil)
    }

    @Test func unrelatedFieldsCannotBeReplacedWithCachedAppFocus() {
        let nodes = [1: Node(owner: 777, isInput: true), 2: Node(owner: 777, isInput: true)]
        #expect(resolve(nodes, system: 2, app: 1) == nil)
    }

    @Test func aWholeWebPageWithoutAFocusedInputStillFallsBack() {
        let nodes = [1: Node(owner: 777), 2: Node(owner: 777, parent: 1, isInput: true)]
        #expect(resolve(nodes, system: 1, app: 1) == nil)
        #expect(resolve(nodes, system: nil, app: 2) == nil)
    }

    @Test func aWebContainerCanIdentifyItsExplicitlyFocusedEditor() {
        let nodes = [
            1: Node(owner: 777, children: [2, 3]),
            2: Node(owner: 777, parent: 1, isInput: true),
            3: Node(owner: 888, parent: 1, isInput: true, isFocused: true),
        ]
        #expect(resolve(nodes, system: 1, app: 1) == 3)
    }

    @Test func anUnfocusedEditorInsideAWebContainerIsNotGuessed() {
        let nodes = [
            1: Node(owner: 777, children: [2]),
            2: Node(owner: 777, parent: 1, isInput: true),
        ]
        #expect(resolve(nodes, system: 1, app: 1) == nil)
    }

    @Test func twoFocusedEditorsInsideAWebContainerAreRefused() {
        let nodes = [
            1: Node(owner: 777, children: [2, 3]),
            2: Node(owner: 777, parent: 1, isInput: true, isFocused: true),
            3: Node(owner: 777, parent: 1, isInput: true, isFocused: true),
        ]
        #expect(resolve(nodes, system: 1, app: 1) == nil)
    }

    @Test func aRendererWithoutProofOfHostOwnershipIsRefused() {
        #expect(resolve([1: Node(owner: 888, isInput: true)], system: 1, app: nil) == nil)
    }

    @Test func brokenParentAndFocusCyclesTerminate() {
        let nodes = [
            1: Node(owner: 777, parent: 2, focusedChild: 2),
            2: Node(owner: 777, parent: 1, focusedChild: 1),
        ]
        #expect(resolve(nodes, system: 1, app: 1) == nil)
    }
}
