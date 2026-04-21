import AppKit
import Testing
@testable import Wink

@Suite("Menu bar shortcut row view")
struct MenuBarShortcutRowViewTests {
    @Test @MainActor
    func groupedRowsUseIndentedContentInsets() throws {
        let row = MenuBarShortcutRowView(presentation: .placeholder)
        let rootStack = try #require(row.subviews.first as? NSStackView)

        let leadingConstraint = try #require(row.constraints.first {
            ($0.firstItem as AnyObject?) === rootStack
                && $0.firstAttribute == .leading
                && ($0.secondItem as AnyObject?) === row
                && $0.secondAttribute == .leading
        })
        let trailingConstraint = try #require(row.constraints.first {
            ($0.firstItem as AnyObject?) === rootStack
                && $0.firstAttribute == .trailing
                && ($0.secondItem as AnyObject?) === row
                && $0.secondAttribute == .trailing
        })

        #expect(leadingConstraint.constant == MenuBarShortcutRowView.contentLeadingInset)
        #expect(trailingConstraint.constant == -MenuBarShortcutRowView.contentTrailingInset)
        #expect(MenuBarShortcutRowView.contentLeadingInset > 12)
    }
}
