import Foundation

/// Keeps checklist items attached to their paragraphs while the text changes. Pure: no views and no store, so every
/// identity rule can be tested directly. Ranges are UTF-16 offsets. A paragraph ends at a line feed.
enum ChecklistEditing {
    /// Paragraph ranges of `text`, excluding line feeds. Empty text has one empty paragraph.
    static func paragraphRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        for index in 0..<text.length where text.character(at: index) == ChecklistSidecar.lineFeed {
            ranges.append(NSRange(location: start, length: index - start))
            start = index + 1
        }
        ranges.append(NSRange(location: start, length: text.length - start))
        return ranges
    }

    /// The index of the paragraph that contains `location`.
    static func paragraphIndex(containing location: Int, in text: NSString) -> Int {
        lineFeeds(in: text, before: location)
    }

    /// The checklist after `replacement` has replaced `range` of `oldText`. Identity rules:
    /// - Typing, deleting, and pasting inside an item keep the item and its checked state.
    /// - Return inside an item keeps the first part as the item. The text after the break becomes a new, unchecked item.
    /// - Joining two paragraphs keeps the identity of the first one if it is an item. The second item is removed.
    /// - Deleting a whole item removes it. Items after the edit keep their identity.
    static func apply(
        _ checklist: ChecklistSidecar?,
        oldText: NSString,
        range: NSRange,
        replacement: String,
        makeID: () -> UUID
    ) -> ChecklistSidecar? {
        guard let checklist, !checklist.items.isEmpty else { return checklist }

        let oldParagraphs = paragraphRanges(in: oldText)
        let newText = oldText.replacingCharacters(in: range, with: replacement) as NSString
        let newParagraphs = paragraphRanges(in: newText)
        let replacementLineFeeds = lineFeeds(in: replacement as NSString, before: (replacement as NSString).length)

        let i = lineFeeds(in: oldText, before: range.location)
        let j = lineFeeds(in: oldText, before: NSMaxRange(range))
        let removedLineFeeds = j - i
        let addedLineFeeds = replacementLineFeeds

        let startParagraph = oldParagraphs[i]
        let endParagraph = oldParagraphs[j]
        let prefixIsNonEmpty = range.location > startParagraph.location
        let suffixIsNonEmpty = NSMaxRange(range) < NSMaxRange(endParagraph)

        // The old item at each old paragraph index, matched by the paragraph start.
        var itemAt: [Int: ChecklistItem] = [:]
        for item in checklist.items {
            if let index = oldParagraphs.firstIndex(where: { $0.location == item.location }) {
                itemAt[index] = item
            }
        }

        // New paragraph index -> identity to keep (its ID and checked state).
        var kept: [Int: (id: UUID, isChecked: Bool)] = [:]
        func keep(_ index: Int, from item: ChecklistItem?) {
            if let item {
                kept[index] = (item.id, item.isChecked)
            }
        }

        if addedLineFeeds == 0 {
            // One merged paragraph. Its text comes from the prefix of the first paragraph, or else from the suffix of the last.
            if prefixIsNonEmpty {
                keep(i, from: itemAt[i])
            } else if suffixIsNonEmpty {
                keep(i, from: itemAt[j])
            } else {
                keep(i, from: itemAt[i] ?? itemAt[j])
            }
        } else {
            if prefixIsNonEmpty {
                keep(i, from: itemAt[i])
            }
            // The last new paragraph carries the suffix. When the edit started and ended in one paragraph that
            // already kept its identity for the prefix, the suffix is a new item instead.
            let suffixMayKeepIdentity = !(prefixIsNonEmpty && i == j)
            if suffixIsNonEmpty, suffixMayKeepIdentity {
                keep(i + addedLineFeeds, from: itemAt[j])
            }
        }

        // Text added by Return or paste after an item continues the checklist with unchecked items.
        let startedInItem = itemAt[i] != nil
        var results: [ChecklistItem] = []
        for index in 0..<newParagraphs.count {
            let paragraph = newParagraphs[index]
            if let identity = kept[index] {
                results.append(ChecklistItem(id: identity.id, isChecked: identity.isChecked, location: paragraph.location, length: paragraph.length))
            } else if startedInItem, addedLineFeeds > 0, index >= i, index <= i + addedLineFeeds {
                results.append(ChecklistItem(id: makeID(), isChecked: false, location: paragraph.location, length: paragraph.length))
            }
        }

        // Items outside the edit move with their paragraphs. Items inside the edit that were not kept are removed.
        for item in checklist.items {
            guard let oldIndex = oldParagraphs.firstIndex(where: { $0.location == item.location }) else { continue }
            if oldIndex < i {
                results.append(item.moved(to: newParagraphs[oldIndex]))
            } else if oldIndex > j {
                let newIndex = oldIndex + addedLineFeeds - removedLineFeeds
                results.append(item.moved(to: newParagraphs[newIndex]))
            }
        }

        return ChecklistSidecar(items: results.sorted { $0.location < $1.location })
    }

    /// The checklist with one item's checked state flipped. Returns nil if the item is not in the list.
    static func toggled(_ checklist: ChecklistSidecar?, itemID: UUID) -> ChecklistSidecar? {
        guard let checklist, checklist.items.contains(where: { $0.id == itemID }) else { return checklist }
        let items = checklist.items.map { item -> ChecklistItem in
            guard item.id == itemID else { return item }
            return ChecklistItem(id: item.id, isChecked: !item.isChecked, location: item.location, length: item.length)
        }
        return ChecklistSidecar(items: items)
    }

    /// Adds an unchecked item to every paragraph that the range touches and that is not already an item.
    static func addingItems(to checklist: ChecklistSidecar?, in text: NSString, covering range: NSRange, makeID: () -> UUID) -> ChecklistSidecar {
        var items = checklist?.items ?? []
        let paragraphs = paragraphRanges(in: text)
        for index in paragraphIndices(in: text, covering: range) {
            let paragraph = paragraphs[index]
            guard !items.contains(where: { $0.location == paragraph.location }) else { continue }
            items.append(ChecklistItem(id: makeID(), isChecked: false, location: paragraph.location, length: paragraph.length))
        }
        return ChecklistSidecar(items: items.sorted { $0.location < $1.location })
    }

    /// Removes the items on every paragraph that the range touches. Text is not changed.
    static func removingItems(from checklist: ChecklistSidecar?, in text: NSString, covering range: NSRange) -> ChecklistSidecar? {
        guard let checklist else { return nil }
        let paragraphs = paragraphRanges(in: text)
        let touched = Set(paragraphIndices(in: text, covering: range).map { paragraphs[$0].location })
        let items = checklist.items.filter { !touched.contains($0.location) }
        return ChecklistSidecar(items: items)
    }

    /// The item on the paragraph that contains `location`, if there is one.
    static func item(at location: Int, in checklist: ChecklistSidecar?, text: NSString) -> ChecklistItem? {
        let paragraphs = paragraphRanges(in: text)
        let start = paragraphs[paragraphIndex(containing: location, in: text)].location
        return checklist?.items.first { $0.location == start }
    }

    // MARK: - Helpers

    /// Paragraph indices touched by `range`. A selection that ends exactly at a paragraph start does not include that paragraph.
    static func paragraphIndices(in text: NSString, covering range: NSRange) -> ClosedRange<Int> {
        let first = paragraphIndex(containing: range.location, in: text)
        guard range.length > 0 else { return first...first }
        let last = paragraphIndex(containing: NSMaxRange(range) - 1, in: text)
        return first...max(first, last)
    }

    private static func lineFeeds(in text: NSString, before position: Int) -> Int {
        var count = 0
        for index in 0..<min(position, text.length) where text.character(at: index) == ChecklistSidecar.lineFeed {
            count += 1
        }
        return count
    }
}

private extension ChecklistItem {
    func moved(to paragraph: NSRange) -> ChecklistItem {
        ChecklistItem(id: id, isChecked: isChecked, location: paragraph.location, length: paragraph.length)
    }
}
