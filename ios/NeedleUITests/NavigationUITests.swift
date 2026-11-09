import XCTest

/// Taps through the app on a simulator against the pretend server the build starts (web/tests/fake_server.py).
/// Every step saves a screenshot; the build publishes them so each screen can be looked at before a release.
class PlatterUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["UITEST_SERVER"] = ProcessInfo.processInfo.environment["UITEST_SERVER"] ?? "http://127.0.0.1:8796"
        app.launchEnvironment["UITEST_USER"] = "mason"
        app.launchEnvironment["UITEST_PASS"] = "pw"
        app.launchArguments += ["-skippedSetup", "YES"]
        app.launch()
    }

    /// Saves a screenshot named for the test and step (kept with the test results, and in SHOT_DIR when set).
    func shot(_ name: String) {
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? s.pngRepresentation.write(to: url)
        }
    }

    func tab(_ name: String) -> XCUIElement { app.buttons["tab-\(name)"].firstMatch }

    @discardableResult
    func waitFor(_ e: XCUIElement, _ seconds: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: seconds), "never showed up: \(e)", file: file, line: line)
        return e
    }

    /// Scrolls up until the element can be tapped (it may be below the screen or behind the tab bar).
    @discardableResult
    func reveal(_ e: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(e.waitForExistence(timeout: 10), "never showed up: \(e)", file: file, line: line)
        var tries = 0
        while tries < 8 && !(e.isHittable && e.frame.minY > 110 && e.frame.maxY < app.frame.maxY - 150) {
            if e.frame.minY <= 110 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
            tries += 1
        }
        return e
    }

    /// Opens Library > Albums > the first album.
    func openFirstAlbum() {
        tab("library").tap()
        waitFor(app.buttons["Albums"]).tap()
        waitFor(app.buttons.matching(identifier: "album-tile").firstMatch, 15).tap()
        waitFor(app.otherElements.matching(identifier: "track-row").firstMatch, 15)
    }

    /// A drag from the very left edge of the screen: the system's "go back" swipe.
    func edgeSwipeBack() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }
}

final class NavigationUITests: PlatterUITestCase {
    func testTabsShowTheirPages() {
        waitFor(tab("home"))
        shot("01-home")
        for t in ["library", "search", "settings", "home"] {
            tab(t).tap()
            sleep(1)
            shot("02-tab-\(t)")
        }
    }

    func testTappingTheTabAgainGoesBackToItsFirstPage() {
        openFirstAlbum()
        shot("10-album")
        tab("library").tap()
        waitFor(app.buttons["Albums"])
        XCTAssertFalse(app.otherElements.matching(identifier: "track-row").firstMatch.exists, "still on the album page")
        shot("11-library-again")
    }

    func testEdgeSwipeGoesBackWithoutQueueingAnything() {
        openFirstAlbum()
        edgeSwipeBack()
        sleep(1)
        shot("20-after-back-swipe")
        XCTAssertTrue(app.buttons.matching(identifier: "album-tile").firstMatch.waitForExistence(timeout: 5), "didn't go back to Albums")
        XCTAssertFalse(app.staticTexts["Added to queue"].exists, "the back swipe queued a song")
    }

    func testSwipingASongLeftShowsQueueAndFavorite() {
        openFirstAlbum()
        let row = app.otherElements.matching(identifier: "track-row").element(boundBy: 1)
        // a short drag left (a long one queues it straight away)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.5)))
        let queue = app.buttons["swipe-queue"].firstMatch
        waitFor(queue, 5)
        XCTAssertTrue(app.buttons["swipe-favorite"].firstMatch.exists)
        shot("30-swipe-buttons")
        queue.tap()
        waitFor(app.staticTexts["Added to queue"], 5)
        shot("31-queued")
    }

    func testSwipingASongAllTheWayLeftQueuesIt() {
        openFirstAlbum()
        let row = app.otherElements.matching(identifier: "track-row").element(boundBy: 3)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)))
        waitFor(app.staticTexts["Added to queue"], 5)
        XCTAssertFalse(app.buttons["swipe-queue"].exists, "closes after queueing")
    }

    func testTappingASongStillPlaysIt() {
        openFirstAlbum()
        app.otherElements.matching(identifier: "track-row").element(boundBy: 4).tap()
        waitFor(app.otherElements["mini-player"], 10)
        XCTAssertFalse(app.staticTexts["Added to queue"].exists)
    }

    func testSwipingASongRightDoesNothing() {
        openFirstAlbum()
        let row = app.otherElements.matching(identifier: "track-row").element(boundBy: 2)
        let a = row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let b = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        a.press(forDuration: 0.05, thenDragTo: b)
        sleep(1)
        XCTAssertFalse(app.staticTexts["Added to queue"].exists, "a right swipe queued a song")
        XCTAssertFalse(app.buttons["swipe-queue"].exists)
    }
}
