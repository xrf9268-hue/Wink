import Testing
@testable import Wink

@Suite("AppPickerPopover highlight state")
struct AppPickerHighlightStateTests {

    @Test
    func searchTextChangeResetsHighlightToFirstResult() {
        var state = AppPickerHighlightState()
        state.reset()
        for _ in 0..<5 {
            _ = state.move(1, count: 10)
        }
        #expect(state.highlightedIndex == 5)

        // Typing a query shrinks the filtered list; the stale index must not
        // survive or Return would silently no-op (Issue #264).
        state.searchTextChanged()

        #expect(state.highlightedIndex == 0)
        let filtered = ["OnlyMatch"]
        #expect(state.selection(in: filtered) == "OnlyMatch")
    }

    @Test
    func selectionReturnsNilWhenIndexIsOutOfBounds() {
        var state = AppPickerHighlightState()
        state.reset()
        _ = state.move(1, count: 6)
        _ = state.move(1, count: 6)
        #expect(state.highlightedIndex == 2)

        #expect(state.selection(in: ["a", "b"]) == nil)
        #expect(state.selection(in: [String]()) == nil)
    }

    @Test
    func moveClampsToListBounds() {
        var state = AppPickerHighlightState()
        state.reset()

        #expect(state.move(-1, count: 3) == 0)
        #expect(state.move(1, count: 3) == 1)
        #expect(state.move(1, count: 3) == 2)
        #expect(state.move(1, count: 3) == 2)
        #expect(state.move(-5, count: 3) == 0)
    }

    @Test
    func moveOnEmptyListLeavesHighlightUntouched() {
        var state = AppPickerHighlightState()
        state.reset()

        #expect(state.move(1, count: 0) == nil)
        #expect(state.highlightedIndex == 0)
    }

    @Test
    func selectionBeforeAppearReturnsNil() {
        let state = AppPickerHighlightState()
        #expect(state.highlightedIndex == nil)
        #expect(state.selection(in: ["a"]) == nil)
    }
}
