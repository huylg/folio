import AppKit
import XCTest
@testable import FolioKit

/// The Columns submenu and the setting behind it.
///
/// The wiring worth pinning is the tag: the menu carries the reader's choice as an `Int` and the
/// action maps it back to a case, so a renumbered enum or a forgotten tag would silently leave
/// every item pointing at "Automatic".
final class ColumnMenuTests: XCTestCase {

    private func columnsSubmenu() throws -> NSMenu {
        // The builder hangs the Services menu off `NSApp`, which does not exist until something
        // asks for it.
        _ = NSApplication.shared
        let main = MainMenuBuilder.build()
        let view = try XCTUnwrap(main.items.first { $0.title == "View" }?.submenu,
                                 "no View menu")
        return try XCTUnwrap(view.items.first { $0.title == "Columns" }?.submenu,
                             "no Columns submenu")
    }

    func testTheSubmenuHasOneItemPerChoice() throws {
        let columns = try columnsSubmenu()
        XCTAssertEqual(columns.items.count, AppSettings.ColumnLayout.offered.count)

        for (item, layout) in zip(columns.items, AppSettings.ColumnLayout.offered) {
            XCTAssertEqual(item.tag, layout.rawValue,
                           "\"\(item.title)\" carries the wrong choice")
            XCTAssertEqual(AppSettings.ColumnLayout(rawValue: item.tag), layout)
            XCTAssertEqual(item.keyEquivalent, "\(layout.rawValue)")
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        }
    }

    /// ⌥⌘2 kept the shortcut the two-column toggle had, so a reader's hand keeps working.
    func testTwoColumnsKeepsItsShortcut() throws {
        let item = try XCTUnwrap(try columnsSubmenu().items.first { $0.keyEquivalent == "2" })
        XCTAssertEqual(AppSettings.ColumnLayout(rawValue: item.tag), .two)
    }

    /// A count past the offered list still stores and comes back, so where the menu stops is a
    /// question about shortcuts rather than a cap on the layout.
    func testACountBeyondTheOfferedListSurvives() throws {
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.columnLayout = .fixed(7)
        XCTAssertEqual(settings.columnLayout.rawValue, 7)
        XCTAssertEqual(settings.columnLayout.limit, 7)
        XCTAssertFalse(AppSettings.ColumnLayout.offered.contains(settings.columnLayout),
                       "the fixture should be past what the menu offers")
    }

    /// The choice a reader picks is the one that comes back, and only that one is ticked.
    func testAChoiceRoundTripsThroughTheDefaults() throws {
        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        for layout in AppSettings.ColumnLayout.offered {
            settings.columnLayout = layout
            XCTAssertEqual(settings.columnLayout, layout)
            XCTAssertEqual(AppSettings.ColumnLayout.offered.filter {
                $0.rawValue == settings.columnLayout.rawValue
            }.count, 1, "two choices claim the same stored value")
        }
    }
}
