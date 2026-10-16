import XCTest
@testable import JAASNotes

/// Checklist identity through edits, paragraph splits and joins, paste, and deletion (03-03). Pure: no views.
final class ChecklistEditingTests: XCTestCase {
    /// Paragraphs: "Buy milk" (0,8), "日本語" (9,3), "😀 smile" (13,8), "Last" (22,4).
    private let text = "Buy milk\n日本語\n😀 smile\nLast" as NSString
    private let first = UUID()
    private let third = UUID()

    /// A checked item on "Buy milk" and an unchecked item on "😀 smile".
    private var checklist: ChecklistSidecar {
        ChecklistSidecar(items: [
            ChecklistItem(id: first, isChecked: true, location: 0, length: 8),
            ChecklistItem(id: third, isChecked: false, location: 13, length: 8),
        ])
    }

    private func apply(_ range: NSRange, _ replacement: String, makeID: @escaping () -> UUID = { UUID() }) -> ChecklistSidecar {
        let result = ChecklistEditing.apply(checklist, oldText: text, range: range, replacement: replacement, makeID: makeID)
        return result!
    }

    private func item(_ id: UUID, in list: ChecklistSidecar) -> ChecklistItem? {
        list.items.first { $0.id == id }
    }

    /// Checks that the result is valid for the text it describes.
    private func assertValid(_ list: ChecklistSidecar, for newText: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try list.validate(against: newText), file: file, line: line)
    }

    // MARK: - Typing

    func testTypingInsideAnItemKeepsItsIdentityAndState() {
        let result = apply(NSRange(location: 3, length: 0), "X")

        XCTAssertEqual(item(first, in: result)?.isChecked, true)
        XCTAssertEqual(item(first, in: result)?.length, 9)
        XCTAssertEqual(item(third, in: result)?.location, 14, "The item after the edit moves with its paragraph.")
        assertValid(result, for: "BuyX milk\n日本語\n😀 smile\nLast")
    }

    func testTypingEmojiInALaterItemKeepsItsIdentity() {
        let result = apply(NSRange(location: 15, length: 0), "🧪")

        XCTAssertEqual(item(third, in: result)?.length, 10)
        XCTAssertEqual(item(third, in: result)?.isChecked, false)
        assertValid(result, for: "Buy milk\n日本語\n😀 🧪smile\nLast")
    }

    // MARK: - Splitting

    func testReturnAtTheEndOfAnItemAddsAnUncheckedItemAfterIt() {
        let newID = UUID()
        let result = apply(NSRange(location: 8, length: 0), "\n") { newID }

        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(item(first, in: result)?.isChecked, true, "The item keeps the text before the break and its state.")
        XCTAssertEqual(item(newID, in: result)?.location, 9)
        XCTAssertEqual(item(newID, in: result)?.isChecked, false)
        XCTAssertEqual(item(third, in: result)?.location, 14)
        assertValid(result, for: "Buy milk\n\n日本語\n😀 smile\nLast")
    }

    func testReturnInTheMiddleOfAnItemSplitsItAndTheTailIsNew() {
        let tailID = UUID()
        let result = apply(NSRange(location: 3, length: 0), "\n") { tailID }

        XCTAssertEqual(item(first, in: result)?.location, 0)
        XCTAssertEqual(item(first, in: result)?.length, 3)
        XCTAssertEqual(item(first, in: result)?.isChecked, true)
        XCTAssertEqual(item(tailID, in: result)?.location, 4)
        XCTAssertEqual(item(tailID, in: result)?.length, 5, "The tail is \" milk\".")
        assertValid(result, for: "Buy\n milk\n日本語\n😀 smile\nLast")
    }

    func testReturnAtTheStartOfAnItemMovesItsIdentityDownWithTheText() {
        let newID = UUID()
        let result = apply(NSRange(location: 0, length: 0), "\n") { newID }

        XCTAssertEqual(item(first, in: result)?.location, 1, "The text, and the checked state, move down with the break.")
        XCTAssertEqual(item(first, in: result)?.isChecked, true)
        XCTAssertEqual(item(newID, in: result)?.location, 0)
        XCTAssertEqual(item(newID, in: result)?.length, 0)
        assertValid(result, for: "\nBuy milk\n日本語\n😀 smile\nLast")
    }

    // MARK: - Joining and deleting

    func testJoiningAPlainParagraphIntoAnItemKeepsTheItemsIdentity() {
        // Delete the line feed after "Buy milk", joining it with "日本語".
        let result = apply(NSRange(location: 8, length: 1), "")

        XCTAssertEqual(item(first, in: result)?.length, 11)
        XCTAssertEqual(item(first, in: result)?.isChecked, true)
        XCTAssertEqual(item(third, in: result)?.location, 12, "The later item moves to its new paragraph.")
        assertValid(result, for: "Buy milk日本語\n😀 smile\nLast")
    }

    func testJoiningAnItemWithAPlainParagraphBeforeItDropsTheItemsIdentity() {
        // Delete the line feed after "日本語", joining it with "😀 smile", which is an item.
        let result = apply(NSRange(location: 12, length: 1), "")

        XCTAssertNil(item(third, in: result), "The second paragraph's item is removed when the paragraphs join.")
        XCTAssertEqual(item(first, in: result)?.location, 0)
        XCTAssertEqual(result.items.count, 1)
        assertValid(result, for: "Buy milk\n日本語😀 smile\nLast")
    }

    func testDeletingAWholeItemRemovesIt() {
        let result = apply(NSRange(location: 0, length: 9), "")

        XCTAssertNil(item(first, in: result), "The deleted item is gone.")
        XCTAssertEqual(item(third, in: result)?.location, 4, "The next item keeps its identity and moves up.")
        XCTAssertEqual(item(third, in: result)?.isChecked, false)
        assertValid(result, for: "日本語\n😀 smile\nLast")
    }

    // MARK: - Paste

    func testPastedLinesInsideAnItemKeepTheItemOnTheLastLine() {
        // Paste "one\ntwo" at the start of "😀 smile".
        let result = apply(NSRange(location: 13, length: 0), "one\ntwo")

        XCTAssertEqual(item(third, in: result)?.location, 17, "The last pasted line carries the original item.")
        XCTAssertEqual(item(third, in: result)?.isChecked, false)
        let continuation = result.items.first { $0.location == 13 }
        XCTAssertNotNil(continuation, "The first pasted line is a new, unchecked item.")
        XCTAssertEqual(continuation?.isChecked, false)
        XCTAssertNotEqual(continuation?.id, third)
        assertValid(result, for: "Buy milk\n日本語\none\ntwo😀 smile\nLast")
    }

    func testPastedTextWithoutLineBreaksChangesNothingButLength() {
        let result = apply(NSRange(location: 0, length: 0), "ok ")

        XCTAssertEqual(item(first, in: result)?.length, 11)
        XCTAssertEqual(item(first, in: result)?.isChecked, true)
        XCTAssertEqual(result.items.count, 2)
    }

    // MARK: - Plain paragraphs and empty checklists

    func testEditsAwayFromItemsOnlyMoveThem() {
        let result = apply(NSRange(location: 22, length: 0), "!!")

        XCTAssertEqual(item(first, in: result), checklist.items[0])
        XCTAssertEqual(item(third, in: result), checklist.items[1])
    }

    func testNoItemsMeansNoChecklist() {
        let result = ChecklistEditing.apply(nil, oldText: text, range: NSRange(location: 0, length: 0), replacement: "\n", makeID: UUID.init)
        XCTAssertNil(result)
    }

    // MARK: - Toggling and paragraph commands

    func testToggleFlipsOnlyTheNamedItem() {
        let result = ChecklistEditing.toggled(checklist, itemID: third)

        XCTAssertEqual(item(third, in: result!)?.isChecked, true)
        XCTAssertEqual(item(first, in: result!)?.isChecked, true)
    }

    func testAddingItemsSkipsParagraphsThatAlreadyHaveOne() {
        let added = ChecklistEditing.addingItems(to: checklist, in: text, covering: NSRange(location: 0, length: 12)) { UUID() }

        XCTAssertEqual(added.items.map(\.location), [0, 9, 13])
        XCTAssertEqual(item(first, in: added)?.isChecked, true, "Existing items keep their state.")
        XCTAssertEqual(added.items.filter { !$0.isChecked }.count, 2)
    }

    func testSelectionThatEndsAtAParagraphStartDoesNotIncludeThatParagraph() {
        let added = ChecklistEditing.addingItems(to: nil, in: text, covering: NSRange(location: 0, length: 9)) { UUID() }

        XCTAssertEqual(added.items.map(\.location), [0])
    }

    func testRemovingItemsLeavesTheText() {
        let removed = ChecklistEditing.removingItems(from: checklist, in: text, covering: NSRange(location: 14, length: 0))

        XCTAssertEqual(removed?.items.map(\.id), [first])
    }

    func testItemAtALocationFindsTheParagraphsItem() {
        XCTAssertEqual(ChecklistEditing.item(at: 17, in: checklist, text: text)?.id, third, "A location inside an item finds it.")
        XCTAssertNil(ChecklistEditing.item(at: 10, in: checklist, text: text))
    }
}
