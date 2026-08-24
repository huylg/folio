import AppKit
import XCTest
@testable import FolioKit

/// The update pill: what it says, and where it lives.
///
/// The placement assertion is the one with history behind it. The obvious home for the badge is a
/// toolbar item, and it would have been wrong: `showWelcomeScreen()` sets `window.toolbar = nil`,
/// so a toolbar item disappears on the one screen a reader with no document open is looking at.
/// It is a titlebar accessory instead, which belongs to the window rather than the toolbar and
/// survives the swap between the two screens.
final class UpdateBadgeTests: XCTestCase {

    private var savedState: UpdateState = .idle

    override func setUp() {
        super.setUp()
        savedState = UpdateController.shared.state
    }

    override func tearDown() {
        UpdateController.shared.setStateForTesting(savedState)
        super.tearDown()
    }

    // MARK: Fixtures

    private func release(_ version: String) -> Release {
        Release(version: AppVersion(version)!,
                tag: "v\(version)",
                notes: "",
                publishedAt: nil,
                assetURL: URL(string: "https://github.com/huylg/folio/x/Folio-v\(version).zip")!,
                assetName: "Folio-v\(version).zip",
                byteCount: 1024,
                checksumURL: nil,
                pageURL: URL(string: "https://github.com/huylg/folio/releases/tag/v\(version)")!)
    }

    private func sampleURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("sample-vault/Drafts")
            .appendingPathComponent("Sparse attention under bounded compute.md")
    }

    private func newWindow() throws -> (MainWindowController, NSWindow) {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(MainWindowController.defaultContentSize)
        window.orderBack(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        return (controller, window)
    }

    private func settle() {
        for _ in 0..<20 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func badgeAccessory(in window: NSWindow) -> UpdateBadgeAccessoryController? {
        window.titlebarAccessoryViewControllers
            .compactMap { $0 as? UpdateBadgeAccessoryController }
            .first
    }

    // MARK: What it says

    /// `.idle` has no appearance at all, which is what hides the pill rather than leaving an
    /// empty capsule in the titlebar.
    func testIdleHasNothingToSay() {
        XCTAssertNil(UpdateBadgeView.appearance(for: .idle))
    }

    func testEveryOtherStateHasALabel() {
        let states: [UpdateState] = [
            .checking,
            .upToDate(AppVersion("1.3.0")!),
            .available(release("1.4.0")),
            .downloading(release("1.4.0"), fraction: 0.5),
            .readyToInstall(release("1.4.0"), bundle: URL(fileURLWithPath: "/tmp/Folio.app")),
            .installing,
            .failed(.network("offline")),
        ]
        for state in states {
            let appearance = UpdateBadgeView.appearance(for: state)
            XCTAssertNotNil(appearance, "\(state) has no label")
            XCTAssertFalse(appearance?.title.isEmpty ?? true, "\(state) has an empty label")
        }
    }

    /// The label a reader actually sees, in the shape the reference design uses.
    func testAnAvailableUpdateNamesTheVersion() {
        let appearance = UpdateBadgeView.appearance(for: .available(release("1.4.0")))
        XCTAssertEqual(appearance?.title, "Update Available: 1.4.0")
    }

    func testProgressIsShownAsAWholePercent() {
        for (fraction, expected) in [(0.0, "0%"), (0.6234, "62%"), (1.0, "100%")] {
            let state = UpdateState.downloading(release("1.4.0"), fraction: fraction)
            XCTAssertEqual(UpdateBadgeView.appearance(for: state)?.title,
                           "Downloading… \(expected)")
        }
    }

    func testReadyToInstallAsksForTheRestartRatherThanReportingAState() {
        let state = UpdateState.readyToInstall(release("1.4.0"),
                                               bundle: URL(fileURLWithPath: "/tmp/Folio.app"))
        XCTAssertEqual(UpdateBadgeView.appearance(for: state)?.title,
                       "Restart to Update to 1.4.0")
    }

    // MARK: How it looks

    /// Folio is dark only, and the badge carries small text, so both pairs have to clear the
    /// same floor the rest of the palette is held to.
    func testBothPalettesAreReadable() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let pairs: [(String, UpdateState)] = [
            ("available", .available(release("1.4.0"))),
            ("checking", .checking),
            ("downloading", .downloading(release("1.4.0"), fraction: 0.5)),
            ("failed", .failed(.network("offline"))),
        ]
        for (name, state) in pairs {
            let palette = try XCTUnwrap(UpdateBadgeView.appearance(for: state)?.palette)
            let backdrop = palette.fill.flattened(over: Ink.page, appearance: appearance)
                ?? palette.fill
            let ratio = palette.text.contrastRatio(on: backdrop, appearance: appearance) ?? 0
            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                                        "the \(name) badge measures \(ratio):1 against its fill")
        }
    }

    func testTheBadgeIsWideEnoughForItsLabel() {
        let badge = UpdateBadgeView(frame: .zero)
        badge.apply(.available(release("1.4.0")))
        let narrow = badge.intrinsicContentSize

        badge.apply(.readyToInstall(release("1.4.0"),
                                    bundle: URL(fileURLWithPath: "/tmp/Folio.app")))
        let wide = badge.intrinsicContentSize

        XCTAssertGreaterThan(narrow.width, 0)
        XCTAssertGreaterThan(wide.width, narrow.width,
                             "a longer label must ask for more room, not clip")
        XCTAssertGreaterThan(narrow.height, 0)
    }

    func testTheBadgeHidesItselfWhenThereIsNothingToSay() {
        let badge = UpdateBadgeView(frame: .zero)
        badge.apply(.available(release("1.4.0")))
        XCTAssertFalse(badge.isHidden)
        XCTAssertEqual(badge.title, "Update Available: 1.4.0")

        badge.apply(.idle)
        XCTAssertTrue(badge.isHidden)
    }

    // MARK: Where it lives

    /// The regression this file exists for: the badge is in the titlebar on the welcome screen,
    /// on the reading screen, and after navigating back — a toolbar item would have failed the
    /// first and third of those.
    func testTheBadgeSurvivesBothScreensAndTheNavigationBetweenThem() throws {
        let (controller, window) = try newWindow()

        XCTAssertNil(window.toolbar, "the welcome screen has no toolbar, which is the whole point")
        XCTAssertNotNil(badgeAccessory(in: window), "no badge on the welcome screen")

        controller.openDocument(sampleURL())
        settle()
        XCTAssertNotNil(window.toolbar, "the reading screen should have brought its toolbar")
        XCTAssertNotNil(badgeAccessory(in: window), "no badge on the reading screen")

        controller.goBack(nil)
        settle()
        XCTAssertNil(window.toolbar)
        XCTAssertNotNil(badgeAccessory(in: window), "the badge did not survive going back")
    }

    /// Every window gets its own, so a second window opened during a download is not the one
    /// window without a pill.
    func testASecondWindowGetsItsOwnBadge() throws {
        let (_, first) = try newWindow()
        let (_, second) = try newWindow()
        XCTAssertNotNil(badgeAccessory(in: first))
        XCTAssertNotNil(badgeAccessory(in: second))
        XCTAssertFalse(badgeAccessory(in: first) === badgeAccessory(in: second))
    }

    /// Regression cover for a pill that was present, unhidden, laid out — and 0pt wide.
    ///
    /// A titlebar accessory is positioned by AppKit from its view's frame, and AppKit never
    /// consults the fitting size to set one. Under autolayout the container came out zero-width
    /// with a correct 153pt `fittingSize` sitting next to it, so every assertion about the badge
    /// existing passed while nothing was on screen. Measure the frame, not the existence.
    func testTheBadgeHasRealSizeOnBothScreens() throws {
        let (controller, window) = try newWindow()
        UpdateController.shared.setStateForTesting(.available(release("1.4.0")))
        settle()
        let accessory = try XCTUnwrap(badgeAccessory(in: window))

        func assertVisible(_ screen: String) {
            let badge = accessory.badgeView
            XCTAssertGreaterThan(badge.frame.width, 0, "the badge is zero-width on the \(screen)")
            XCTAssertGreaterThan(badge.frame.height, 0, "the badge is zero-height on the \(screen)")
            XCTAssertGreaterThanOrEqual(accessory.view.frame.width, badge.frame.width,
                                        "the accessory is narrower than the badge it holds")
            XCTAssertGreaterThan(accessory.view.frame.height, 0)
            // Inside its container, not spilling out of the titlebar.
            XCTAssertLessThanOrEqual(badge.frame.maxY, accessory.view.frame.height + 1)
            XCTAssertGreaterThanOrEqual(badge.frame.minY, -1)
        }

        assertVisible("welcome screen")

        controller.openDocument(sampleURL())
        settle()
        assertVisible("reading screen")

        controller.goBack(nil)
        settle()
        assertVisible("welcome screen after going back")
    }

    /// A wider label needs a wider accessory, or the pill is clipped rather than shown.
    func testTheAccessoryGrowsWithTheLabel() throws {
        let (_, window) = try newWindow()
        let accessory = try XCTUnwrap(badgeAccessory(in: window))

        UpdateController.shared.setStateForTesting(.available(release("1.4.0")))
        settle()
        let narrow = accessory.view.frame.width

        UpdateController.shared.setStateForTesting(
            .readyToInstall(release("1.4.0"), bundle: URL(fileURLWithPath: "/tmp/Folio.app")))
        settle()
        XCTAssertGreaterThan(accessory.view.frame.width, narrow,
                             "a longer label must widen the accessory, not clip inside it")

        UpdateController.shared.setStateForTesting(.idle)
        settle()
        XCTAssertEqual(accessory.view.frame.width, 0,
                       "a hidden badge should reserve no titlebar space")
    }

    // MARK: The secondary click

    private func rightClick() throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
                                         modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Regression cover: the menu was first hung off the button's action, inspecting
    /// `NSApp.currentEvent` for a right-click. `NSButton` does not send its action on the right
    /// button at all, so skipping a version and cancelling a download were both unreachable while
    /// looking, in the source, as though they were wired up. It goes through `menu(for:)` now,
    /// which is what AppKit actually routes a secondary click to.
    func testTheSecondaryClickOffersTheActionsForTheState() throws {
        let (_, window) = try newWindow()
        let badge = try XCTUnwrap(badgeAccessory(in: window)).badgeView

        UpdateController.shared.setStateForTesting(.available(release("1.4.0")))
        settle()
        let offered = try XCTUnwrap(badge.menu(for: try rightClick()),
                                    "an available update should offer a menu")
        XCTAssertTrue(offered.items.contains { $0.title == "Skip This Version" })
        XCTAssertTrue(offered.items.contains { $0.title.contains("What’s New") })

        UpdateController.shared.setStateForTesting(.downloading(release("1.4.0"), fraction: 0.3))
        settle()
        let downloading = try XCTUnwrap(badge.menu(for: try rightClick()))
        XCTAssertTrue(downloading.items.contains { $0.title == "Cancel Download" })
        XCTAssertFalse(downloading.items.contains { $0.title == "Dismiss" },
                       "a download in progress is not something to dismiss")

        UpdateController.shared.setStateForTesting(.failed(.network("offline")))
        settle()
        let failed = try XCTUnwrap(badge.menu(for: try rightClick()))
        XCTAssertTrue(failed.items.contains { $0.title == "Try Again" })
        XCTAssertTrue(failed.items.contains { $0.title == UpdateError.network("offline").message },
                      "the reason should be readable, not just \"Update Failed\"")
    }

    /// The badge redraws off the notification rather than being pushed to, which is what lets a
    /// window opened mid-download pick up the state it finds.
    func testTheBadgeFollowsTheControllerWithoutBeingTold() throws {
        let (_, window) = try newWindow()
        let accessory = try XCTUnwrap(badgeAccessory(in: window))

        UpdateController.shared.setStateForTesting(.idle)
        settle()
        XCTAssertTrue(accessory.badgeView.isHidden)
        XCTAssertTrue(accessory.isHidden, "the accessory should not reserve titlebar space")

        UpdateController.shared.setStateForTesting(.available(release("1.9.0")))
        settle()
        XCTAssertFalse(accessory.badgeView.isHidden)
        XCTAssertEqual(accessory.badgeView.title, "Update Available: 1.9.0")
        XCTAssertFalse(accessory.isHidden)

        UpdateController.shared.setStateForTesting(.idle)
        settle()
        XCTAssertTrue(accessory.badgeView.isHidden)
    }
}
