import XCTest

/// Every built-in look, photographed on the main screens, plus the Appearance editor itself.
class LookTourCase: PlatterUITestCase {
    /// Photographs one look on Home, an album, the mini player, Now Playing and Settings.
    func tour(_ n: Int, _ look: String) {
        waitFor(tab("home"))
        sleep(2)
        shot("look-\(n)-\(look)-1-home")
        openFirstAlbum()
        sleep(1)
        shot("look-\(n)-\(look)-2-album")
        app.otherElements.matching(identifier: "track-row").element(boundBy: 1).tap()
        let mini = waitFor(app.otherElements["mini-player"], 10)
        sleep(1)
        shot("look-\(n)-\(look)-3-mini")
        mini.tap()
        waitFor(app.buttons["np-close"], 10)
        sleep(2)
        shot("look-\(n)-\(look)-4-nowplaying")
        app.buttons["np-close"].tap()
        sleep(1)
        tab("settings").tap()
        sleep(1)
        shot("look-\(n)-\(look)-5-settings")
    }
}

final class LookUITests: PlatterUITestCase {

    override var startLook: String? { "chrome" }

    func testTheAppearanceEditor() {
        tab("settings").tap()
        let link = app.buttons["settings-appearance"].firstMatch
        if !link.waitForExistence(timeout: 5) { app.swipeUp() }
        waitFor(link).tap()
        waitFor(app.buttons["look-chrome"].firstMatch)
        shot("editor-1-top")
        // pick another look, then change single settings
        app.buttons["look-neon"].firstMatch.tap()
        sleep(1)
        shot("editor-2-neon")
        app.swipeUp()
        sleep(1)
        shot("editor-3-options")
        for chip in ["chip-Sparkles", "chip-Bubbly", "chip-Glossy", "chip-Dock"] {
            reveal(app.buttons[chip].firstMatch).tap()
        }
        sleep(1)
        shot("editor-4-customized")
        reveal(app.buttons["chip-Cassette"].firstMatch).tap()
        reveal(app.buttons["look-save"].firstMatch).tap()
        let field = app.alerts.textFields.firstMatch
        waitFor(field, 5).tap()
        field.typeText(" Test")
        app.alerts.buttons["Save"].tap()
        sleep(1)
        shot("editor-5-saved")
        // the saved look is first in the list now
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        shot("editor-6-your-looks")
    }

    func testHomeLayoutEditor() {
        tab("settings").tap()
        let link = app.buttons["settings-home-layout"].firstMatch
        if !link.waitForExistence(timeout: 5) { app.swipeUp() }
        waitFor(link).tap()
        sleep(1)
        shot("layout-1")
        let toggle = app.switches["Show Quick Picks"].firstMatch
        waitFor(toggle).tap()
        sleep(1)
        shot("layout-2-quick-picks-off")
        tab("home").tap()
        sleep(2)
        shot("layout-3-home-without-quick-picks")
        // put it back for other tests
        tab("settings").tap()
        waitFor(app.switches["Show Quick Picks"].firstMatch).tap()
    }
}

// One test per look, each starting the app fresh in that look.
final class Look0ChromeUITests: LookTourCase {
    override var startLook: String? { "chrome" }
    func testTour() { tour(0, "chrome") }
}

final class Look1BurnedUITests: LookTourCase {
    override var startLook: String? { "burned" }
    func testTour() { tour(1, "burned") }
}

final class Look2NeonUITests: LookTourCase {
    override var startLook: String? { "neon" }
    func testTour() { tour(2, "neon") }
}

final class Look3AnalogUITests: LookTourCase {
    override var startLook: String? { "analog" }
    func testTour() { tour(3, "analog") }
}

final class Look4GlowUITests: LookTourCase {
    override var startLook: String? { "glow" }
    func testTour() { tour(4, "glow") }
}

final class Look5VinylUITests: LookTourCase {
    override var startLook: String? { "vinyl" }
    func testTour() { tour(5, "vinyl") }
}

final class Look6ClassicUITests: LookTourCase {
    override var startLook: String? { "classic" }
    func testTour() { tour(6, "classic") }
}

